//
//  StreamCacheTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the TTL stream cache (hit/miss/expiry/remove/clear).
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

static void testSetGetRemove(void) {
    StreamCache &cache = StreamCache::shared();

    CHECK(cache.get("t1") == nil, "miss on empty cache");

    JLTidalPlaybackInfo *info = makeInfo(@"t1");
    cache.set("t1", info);
    CHECK(cache.get("t1") == info, "hit returns the stored object");
    CHECK_EQ(cache.size(), (size_t)1, "size 1 after set");

    cache.remove("t1");
    CHECK(cache.get("t1") == nil, "miss after remove");

    // Degenerate keys are ignored, not crashes
    cache.set("", info);
    CHECK(cache.get("") == nil, "empty key ignored");
}

static void testExpiry(void) {
    StreamCache &cache = StreamCache::shared();

    cache.setWithTTL("expired", makeInfo(@"expired"), -1);
    CHECK(cache.get("expired") == nil, "expired entry not returned");
    CHECK_EQ(cache.size(), (size_t)0, "expired entry evicted on get");

    cache.setWithTTL("alive", makeInfo(@"alive"), 60);
    cache.setWithTTL("dead", makeInfo(@"dead"), -1);
    cache.purgeExpired();
    CHECK_EQ(cache.size(), (size_t)1, "purge drops only expired entries");
    CHECK(cache.get("alive") != nil, "live entry survives purge");
}

static void testClearAndShutdown(void) {
    StreamCache &cache = StreamCache::shared();

    cache.set("a", makeInfo(@"a"));
    cache.set("b", makeInfo(@"b"));
    cache.clear();
    CHECK_EQ(cache.size(), (size_t)0, "clear empties the cache");

    cache.set("c", makeInfo(@"c"));
    cache.shutdown();
    CHECK(cache.get("c") == nil, "no reads after shutdown");
    cache.set("d", makeInfo(@"d"));  // must be a no-op, not a crash
    CHECK_EQ(cache.size(), (size_t)0, "no writes after shutdown");
}

int main(void) {
    @autoreleasepool {
        testSetGetRemove();
        testExpiry();
        testClearAndShutdown();  // must run last -- shutdown is terminal
    }
    return testHarnessFinish("StreamCache");
}
