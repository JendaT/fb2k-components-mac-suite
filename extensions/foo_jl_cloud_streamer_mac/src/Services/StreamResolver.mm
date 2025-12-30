#import "StreamResolver.h"
#import "YtDlpWrapper.h"
#import "../Core/CloudConfig.h"
#import "../Core/URLUtils.h"
#import "../Core/StreamCache.h"
#import "../Core/MetadataCache.h"

namespace cloud_streamer {

StreamResolver& StreamResolver::shared() {
    static StreamResolver instance;
    return instance;
}

StreamResolver::StreamResolver()
    : m_queue(dispatch_queue_create("com.jl.cloudstreamer.resolver", DISPATCH_QUEUE_SERIAL))
    , m_resolvingURLs([[NSMutableSet alloc] init])
    , m_shutdown(false)
    , m_initialized(false) {
}

StreamResolver::~StreamResolver() {
    shutdown();
}

void StreamResolver::initialize() {
    if (m_initialized) return;
    m_initialized = true;
    logDebug("StreamResolver initialized");
}

void StreamResolver::shutdown() {
    if (m_shutdown) return;
    m_shutdown = true;

    dispatch_sync(m_queue, ^{
        [m_resolvingURLs removeAllObjects];
    });

    logDebug("StreamResolver shutdown complete");
}

std::string StreamResolver::internalToWebURL(const std::string& internalURL) {
    ParsedCloudURL parsed = URLUtils::parseURL(internalURL);
    return URLUtils::internalSchemeToWebURL(internalURL);
}

bool StreamResolver::isResolving(const std::string& internalURL) {
    if (m_shutdown || internalURL.empty()) return false;

    __block bool result = false;
    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];

    dispatch_sync(m_queue, ^{
        result = [m_resolvingURLs containsObject:key];
    });

    return result;
}

ResolveResult StreamResolver::resolve(const std::string& internalURL,
                                      std::atomic<bool>* abortFlag) {
    return doResolve(internalURL, false, abortFlag);
}

ResolveResult StreamResolver::resolveBypassCache(const std::string& internalURL,
                                                  std::atomic<bool>* abortFlag) {
    return doResolve(internalURL, true, abortFlag);
}

ResolveResult StreamResolver::doResolve(const std::string& internalURL,
                                        bool bypassCache,
                                        std::atomic<bool>* abortFlag) {
    ResolveResult result;
    result.success = false;
    result.error = JLCloudError::None;

    if (m_shutdown) {
        result.error = JLCloudError::Cancelled;
        result.errorMessage = "Resolver is shutdown";
        return result;
    }

    if (internalURL.empty()) {
        result.error = JLCloudError::InvalidURL;
        result.errorMessage = "Empty URL";
        return result;
    }

    // Check abort flag
    if (abortFlag && abortFlag->load()) {
        result.error = JLCloudError::Cancelled;
        result.errorMessage = "Operation cancelled";
        return result;
    }

    // Check stream cache first (unless bypassing)
    if (!bypassCache) {
        auto cached = StreamCache::shared().get(internalURL);
        if (cached.has_value()) {
            result.success = true;
            result.streamURL = cached->streamURL;

            // Also get metadata from cache
            result.trackInfo = MetadataCache::shared().get(internalURL);

            logDebug("StreamResolver: cache hit for " + internalURL);
            return result;
        }
    }

    // Mark as resolving
    NSString* urlKey = [NSString stringWithUTF8String:internalURL.c_str()];
    dispatch_sync(m_queue, ^{
        [m_resolvingURLs addObject:urlKey];
    });

    // Convert to web URL for yt-dlp
    std::string webURL = internalToWebURL(internalURL);
    if (webURL.empty()) {
        result.error = JLCloudError::InvalidURL;
        result.errorMessage = "Failed to convert internal URL to web URL";
        dispatch_sync(m_queue, ^{
            [m_resolvingURLs removeObject:urlKey];
        });
        return result;
    }

    logDebug("StreamResolver: extracting stream for " + webURL);

    // Extract stream URL using yt-dlp
    YtDlpWrapper& ytdlp = YtDlpWrapper::shared();

    // Validate yt-dlp binary first
    std::string ytdlpPath = ytdlp.getYtDlpPath();
    if (ytdlpPath.empty() || !ytdlp.validateBinary(ytdlpPath)) {
        result.error = JLCloudError::YtDlpNotFound;
        result.errorMessage = "yt-dlp binary not configured or invalid";
        dispatch_sync(m_queue, ^{
            [m_resolvingURLs removeObject:urlKey];
        });
        return result;
    }

    // Check abort again
    if (abortFlag && abortFlag->load()) {
        result.error = JLCloudError::Cancelled;
        result.errorMessage = "Operation cancelled";
        dispatch_sync(m_queue, ^{
            [m_resolvingURLs removeObject:urlKey];
        });
        return result;
    }

    // Extract stream URL with metadata
    auto extractResult = ytdlp.extractMetadata(webURL, abortFlag);

    // Remove from resolving set
    dispatch_sync(m_queue, ^{
        [m_resolvingURLs removeObject:urlKey];
    });

    if (!extractResult.success) {
        result.error = extractResult.error;
        result.errorMessage = extractResult.errorMessage;
        return result;
    }

    if (extractResult.streamURL.empty()) {
        result.error = JLCloudError::YtDlpFailed;
        result.errorMessage = "No stream URL extracted";
        return result;
    }

    // Success - cache the results
    result.success = true;
    result.streamURL = extractResult.streamURL;
    result.trackInfo = extractResult.trackInfo;

    // Determine service from URL
    ParsedCloudURL parsed = URLUtils::parseURL(internalURL);
    CloudService service = parsed.service;

    // Cache stream URL
    StreamCache::shared().set(internalURL, result.streamURL, service);

    // Cache metadata if available
    if (result.trackInfo.has_value()) {
        TrackInfo info = result.trackInfo.value();
        info.internalURL = internalURL;
        info.webURL = webURL;
        info.service = service;
        MetadataCache::shared().set(internalURL, info);
    }

    logDebug("StreamResolver: resolved " + internalURL + " -> stream URL obtained");
    return result;
}

void StreamResolver::resolveAsync(const std::string& internalURL,
                                  ResolveCallback callback,
                                  std::atomic<bool>* abortFlag) {
    if (m_shutdown || internalURL.empty()) {
        ResolveResult result;
        result.success = false;
        result.error = m_shutdown ? JLCloudError::Cancelled : JLCloudError::InvalidURL;
        result.errorMessage = m_shutdown ? "Resolver is shutdown" : "Empty URL";
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(result);
        });
        return;
    }

    // Capture variables for block
    std::string urlCopy = internalURL;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ResolveResult result = resolve(urlCopy, abortFlag);
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(result);
        });
    });
}

void StreamResolver::prefetch(const std::string& internalURL) {
    if (m_shutdown || internalURL.empty()) return;

    // Check if already cached
    auto cached = StreamCache::shared().get(internalURL);
    if (cached.has_value()) {
        logDebug("StreamResolver: prefetch skipped (already cached) for " + internalURL);
        return;
    }

    // Check if already resolving
    if (isResolving(internalURL)) {
        logDebug("StreamResolver: prefetch skipped (already resolving) for " + internalURL);
        return;
    }

    logDebug("StreamResolver: prefetching " + internalURL);

    // Resolve in background with no abort flag
    std::string urlCopy = internalURL;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        if (!m_shutdown) {
            resolve(urlCopy, nullptr);
        }
    });
}

void StreamResolver::cancelPrefetch() {
    // Currently prefetch operations use nullptr for abortFlag,
    // so we can't individually cancel them. This clears the
    // resolving set which will cause new operations to start fresh.
    dispatch_sync(m_queue, ^{
        [m_resolvingURLs removeAllObjects];
    });

    logDebug("StreamResolver: prefetch operations cancelled");
}

std::optional<TrackInfo> StreamResolver::getMetadata(const std::string& internalURL,
                                                     std::atomic<bool>* abortFlag) {
    if (m_shutdown || internalURL.empty()) {
        return std::nullopt;
    }

    // Check metadata cache first
    auto cached = MetadataCache::shared().get(internalURL);
    if (cached.has_value()) {
        return cached;
    }

    // Not cached - resolve to get metadata
    auto result = resolve(internalURL, abortFlag);
    if (result.success) {
        return result.trackInfo;
    }

    return std::nullopt;
}

} // namespace cloud_streamer
