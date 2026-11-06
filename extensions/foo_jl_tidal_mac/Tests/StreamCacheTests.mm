//
//  StreamCacheTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the TTL stream cache (hit/miss/expiry/remove/clear) and
//  its per-quality keying.
//

#import <Foundation/Foundation.h>
#import "../src/Core/StreamCache.h"
#include "TestHarness.h"

using tidal::StreamCache;

static JLTidalPlaybackInfo *makeInfo(NSString *trackID) {
    return [[JLTidalPlaybackInfo alloc] initWithDictionary:@{@"audioQuality": @"LOSSLESS"}
                                                   trackID:trackID
                                          requestedQuality:JLTidalQualityLossless];
}

static const JLTidalQuality kQ = JLTidalQualityLossless;

static void testSetGetRemove(void) {
    StreamCache &cache = StreamCache::shared();

    CHECK(cache.get("t1", kQ) == nil, "miss on empty cache");

    JLTidalPlaybackInfo *info = makeInfo(@"t1");
    cache.set("t1", kQ, info);
    CHECK(cache.get("t1", kQ) == info, "hit returns the stored object");
    CHECK_EQ(cache.size(), (size_t)1, "size 1 after set");

    cache.removeTrack("t1");
    CHECK(cache.get("t1", kQ) == nil, "miss after remove");

    // Degenerate keys are ignored, not crashes
    cache.set("", kQ, info);
    CHECK(cache.get("", kQ) == nil, "empty key ignored");
}

// The same track pinned to two qualities resolves to two different CDN URLs,
// so the entries must not shadow each other.
static void testQualityKeying(void) {
    StreamCache &cache = StreamCache::shared();
    cache.clear();

    JLTidalPlaybackInfo *lossless = makeInfo(@"t2");
    JLTidalPlaybackInfo *high = makeInfo(@"t2");
    cache.set("t2", JLTidalQualityLossless, lossless);
    cache.set("t2", JLTidalQualityHigh, high);

    CHECK_EQ(cache.size(), (size_t)2, "same track at two qualities is two entries");
    CHECK(cache.get("t2", JLTidalQualityLossless) == lossless, "LOSSLESS entry intact");
    CHECK(cache.get("t2", JLTidalQualityHigh) == high, "HIGH entry intact");
    CHECK(cache.get("t2", JLTidalQualityLow) == nil, "unstored quality misses");

    // A stale stream URL invalidates the track whichever pin asked for it.
    cache.removeTrack("t2");
    CHECK(cache.get("t2", JLTidalQualityLossless) == nil, "removeTrack drops LOSSLESS");
    CHECK(cache.get("t2", JLTidalQualityHigh) == nil, "removeTrack drops HIGH");

    // Prefix removal must not reach a different track whose id shares a prefix.
    cache.set("t2", kQ, lossless);
    cache.set("t22", kQ, high);
    cache.removeTrack("t2");
    CHECK(cache.get("t22", kQ) == high, "removeTrack does not touch a prefix-sharing id");
    cache.clear();
}

static void testExpiry(void) {
    StreamCache &cache = StreamCache::shared();

    cache.setWithTTL("expired", kQ, makeInfo(@"expired"), -1);
    CHECK(cache.get("expired", kQ) == nil, "expired entry not returned");
    CHECK_EQ(cache.size(), (size_t)0, "expired entry evicted on get");

    cache.setWithTTL("alive", kQ, makeInfo(@"alive"), 60);
    cache.setWithTTL("dead", kQ, makeInfo(@"dead"), -1);
    cache.purgeExpired();
    CHECK_EQ(cache.size(), (size_t)1, "purge drops only expired entries");
    CHECK(cache.get("alive", kQ) != nil, "live entry survives purge");
}

static void testClearAndShutdown(void) {
    StreamCache &cache = StreamCache::shared();

    cache.set("a", kQ, makeInfo(@"a"));
    cache.set("b", kQ, makeInfo(@"b"));
    cache.clear();
    CHECK_EQ(cache.size(), (size_t)0, "clear empties the cache");

    cache.set("c", kQ, makeInfo(@"c"));
    cache.shutdown();
    CHECK(cache.get("c", kQ) == nil, "no reads after shutdown");
    cache.set("d", kQ, makeInfo(@"d"));  // must be a no-op, not a crash
    CHECK_EQ(cache.size(), (size_t)0, "no writes after shutdown");
}

int main(void) {
    @autoreleasepool {
        testSetGetRemove();
        testQualityKeying();
        testExpiry();
        testClearAndShutdown();  // must run last -- shutdown is terminal
    }
    return testHarnessFinish("StreamCache");
}
