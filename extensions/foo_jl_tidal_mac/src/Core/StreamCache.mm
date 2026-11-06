//
//  StreamCache.mm
//  foo_jl_tidal_mac
//
//  Thread-safe TTL cache implementation
//

#import "StreamCache.h"
#include "TidalLog.h"
#import "../API/TidalConstants.h"

namespace tidal {

StreamCache& StreamCache::shared() {
    static StreamCache instance;
    return instance;
}

StreamCache::StreamCache()
    : m_queue(dispatch_queue_create("com.foobar2000.tidal.streamcache", DISPATCH_QUEUE_SERIAL))
    , m_cache([[NSMutableDictionary alloc] init])
    , m_shutdown(false) {
    logDebug("StreamCache initialized");
}

StreamCache::~StreamCache() {
    shutdown();
}

void StreamCache::shutdown() {
    if (m_shutdown.exchange(true)) return;

    dispatch_sync(m_queue, ^{
        [m_cache removeAllObjects];
    });

    // Don't call logDebug here - this may run from the static destructor
    // after fb2k's service infrastructure (configStore) is already torn down.
    // logDebug calls configStore::get() which would uBugCheck.
}

// Track IDs are digits-only (validated in URLUtils::parseURL), so "|" cannot
// occur in one and the composed key is unambiguous.
static NSString* cacheKey(const std::string& trackID, JLTidalQuality quality) {
    return [NSString stringWithFormat:@"%s|%@", trackID.c_str(), JLTidalQualityToString(quality)];
}

JLTidalPlaybackInfo* StreamCache::get(const std::string& trackID, JLTidalQuality quality) {
    if (m_shutdown || trackID.empty()) {
        return nil;
    }

    __block JLTidalPlaybackInfo* result = nil;
    NSString* key = cacheKey(trackID, quality);

    dispatch_sync(m_queue, ^{
        JLTidalStreamCacheEntry* entry = m_cache[key];
        if (entry && !entry.isExpired) {
            result = entry.playbackInfo;
        } else if (entry) {
            // Expired - remove it
            [m_cache removeObjectForKey:key];
        }
    });

    if (result) {
        logDebug(std::string("StreamCache hit: ") + std::string(key.UTF8String));
    }

    return result;
}

void StreamCache::set(const std::string& trackID, JLTidalQuality quality, JLTidalPlaybackInfo* info) {
    setWithTTL(trackID, quality, info, static_cast<int>(kTidalStreamCacheTTL));
}

void StreamCache::setWithTTL(const std::string& trackID, JLTidalQuality quality,
                             JLTidalPlaybackInfo* info, int ttlSeconds) {
    if (m_shutdown || trackID.empty() || !info) {
        return;
    }

    // Drop expired entries opportunistically so the cache cannot grow
    // without bound (expired entries were otherwise only removed on a
    // same-trackID lookup). Runs async on the same serial queue.
    purgeExpired();

    NSString* key = cacheKey(trackID, quality);

    dispatch_async(m_queue, ^{
        JLTidalStreamCacheEntry* entry = [[JLTidalStreamCacheEntry alloc]
            initWithPlaybackInfo:info
                             ttl:ttlSeconds];
        m_cache[key] = entry;
    });

    logDebug(std::string("StreamCache set: ") + std::string(key.UTF8String) +
             " (TTL: " + std::to_string(ttlSeconds) + "s)");
}

void StreamCache::removeTrack(const std::string& trackID) {
    if (m_shutdown || trackID.empty()) return;

    NSString* prefix = [NSString stringWithFormat:@"%s|", trackID.c_str()];

    dispatch_async(m_queue, ^{
        NSMutableArray<NSString*>* keysToRemove = [[NSMutableArray alloc] init];
        for (NSString* key in m_cache) {
            if ([key hasPrefix:prefix]) [keysToRemove addObject:key];
        }
        [m_cache removeObjectsForKeys:keysToRemove];
    });

    logDebug(std::string("StreamCache remove: ") + trackID + " (all qualities)");
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
        NSMutableArray<NSString*>* keysToRemove = [[NSMutableArray alloc] init];

        for (NSString* key in m_cache) {
            JLTidalStreamCacheEntry* entry = m_cache[key];
            if (entry.isExpired) {
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

} // namespace tidal
