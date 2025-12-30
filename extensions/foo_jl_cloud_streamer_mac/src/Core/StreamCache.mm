#import "StreamCache.h"
#import "CloudConfig.h"

// Internal wrapper to store entry data in NSDictionary
// Must be outside namespace for Objective-C compatibility
@interface JLStreamCacheEntryWrapper : NSObject
@property (nonatomic, copy) NSString* streamURL;
@property (nonatomic, assign) int64_t expiresAtMs;
@property (nonatomic, assign) int serviceValue; // Store as int to avoid namespace issues
@end

@implementation JLStreamCacheEntryWrapper
@end

namespace cloud_streamer {

StreamCache& StreamCache::shared() {
    static StreamCache instance;
    return instance;
}

StreamCache::StreamCache()
    : m_queue(dispatch_queue_create("com.jl.cloudstreamer.streamcache", DISPATCH_QUEUE_SERIAL))
    , m_cache([[NSMutableDictionary alloc] init])
    , m_shutdown(false) {
    logDebug("StreamCache initialized");
}

StreamCache::~StreamCache() {
    shutdown();
}

void StreamCache::shutdown() {
    if (m_shutdown) return;
    m_shutdown = true;

    dispatch_sync(m_queue, ^{
        [m_cache removeAllObjects];
    });

    logDebug("StreamCache shutdown complete");
}

int StreamCache::getTTLForService(CloudService service) {
    switch (service) {
        case CloudService::Mixcloud:
            return kMixcloudTTL;
        case CloudService::SoundCloud:
            return kSoundCloudTTL;
        default:
            return kDefaultTTL;
    }
}

std::optional<StreamCacheEntry> StreamCache::get(const std::string& internalURL) {
    if (m_shutdown || internalURL.empty()) {
        return std::nullopt;
    }

    __block std::optional<StreamCacheEntry> result = std::nullopt;
    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];

    dispatch_sync(m_queue, ^{
        JLStreamCacheEntryWrapper* wrapper = m_cache[key];
        if (wrapper) {
            // Convert stored ms timestamp to steady_clock time_point
            auto now = std::chrono::steady_clock::now();
            auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                now.time_since_epoch()).count();

            if (wrapper.expiresAtMs > nowMs) {
                StreamCacheEntry entry;
                entry.streamURL = std::string([wrapper.streamURL UTF8String]);
                entry.service = static_cast<CloudService>(wrapper.serviceValue);
                // Reconstruct time_point from stored expiry
                auto remaining = wrapper.expiresAtMs - nowMs;
                entry.expiresAt = now + std::chrono::milliseconds(remaining);
                result = entry;
            } else {
                // Expired - remove it
                [m_cache removeObjectForKey:key];
            }
        }
    });

    if (result.has_value()) {
        logDebug(std::string("StreamCache hit: ") + internalURL);
    }

    return result;
}

void StreamCache::set(const std::string& internalURL,
                      const std::string& streamURL,
                      CloudService service) {
    setWithTTL(internalURL, streamURL, service, getTTLForService(service));
}

void StreamCache::setWithTTL(const std::string& internalURL,
                             const std::string& streamURL,
                             CloudService service,
                             int ttlSeconds) {
    if (m_shutdown || internalURL.empty() || streamURL.empty()) {
        return;
    }

    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];
    NSString* url = [NSString stringWithUTF8String:streamURL.c_str()];
    int serviceVal = static_cast<int>(service);

    // Calculate expiry as ms since epoch of steady_clock
    auto expiresAt = std::chrono::steady_clock::now() + std::chrono::seconds(ttlSeconds);
    int64_t expiresAtMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        expiresAt.time_since_epoch()).count();

    dispatch_async(m_queue, ^{
        JLStreamCacheEntryWrapper* wrapper = [[JLStreamCacheEntryWrapper alloc] init];
        wrapper.streamURL = url;
        wrapper.expiresAtMs = expiresAtMs;
        wrapper.serviceValue = serviceVal;
        m_cache[key] = wrapper;
    });

    logDebug(std::string("StreamCache set: ") + internalURL +
             " (TTL: " + std::to_string(ttlSeconds) + "s)");
}

void StreamCache::remove(const std::string& internalURL) {
    if (m_shutdown || internalURL.empty()) return;

    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];

    dispatch_async(m_queue, ^{
        [m_cache removeObjectForKey:key];
    });

    logDebug(std::string("StreamCache remove: ") + internalURL);
}

void StreamCache::clear() {
    if (m_shutdown) return;

    dispatch_async(m_queue, ^{
        [m_cache removeAllObjects];
    });

    logDebug("StreamCache cleared");
}

void StreamCache::purgeExpired() {
    if (m_shutdown) return;

    dispatch_async(m_queue, ^{
        auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();

        NSMutableArray<NSString*>* keysToRemove = [[NSMutableArray alloc] init];

        for (NSString* key in m_cache) {
            JLStreamCacheEntryWrapper* wrapper = m_cache[key];
            if (wrapper.expiresAtMs <= nowMs) {
                [keysToRemove addObject:key];
            }
        }

        if (keysToRemove.count > 0) {
            [m_cache removeObjectsForKeys:keysToRemove];
            logDebug(std::string("StreamCache purged ") +
                     std::to_string(keysToRemove.count) + " expired entries");
        }
    });
}

size_t StreamCache::size() {
    if (m_shutdown) return 0;

    __block size_t count = 0;
    dispatch_sync(m_queue, ^{
        count = m_cache.count;
    });
    return count;
}

size_t StreamCache::expiredCount() {
    if (m_shutdown) return 0;

    __block size_t count = 0;
    dispatch_sync(m_queue, ^{
        auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();

        for (NSString* key in m_cache) {
            JLStreamCacheEntryWrapper* wrapper = m_cache[key];
            if (wrapper.expiresAtMs <= nowMs) {
                count++;
            }
        }
    });
    return count;
}

} // namespace cloud_streamer
