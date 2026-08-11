//
//  CachePolicyTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/CachePolicy.h"

using namespace waveseek;

namespace {

void testSizeConversion() {
    TEST_CASE("size conversion");

    CHECK(bytesFromMegabytes(1) == 1048576, "one megabyte is 1024 KiB");
    CHECK(bytesFromMegabytes(2048) == 2147483648LL, "the default 2GB limit does not overflow");
    CHECK(bytesFromMegabytes(0) == 0, "no limit converts to zero bytes");
}

void testEvictionUnderLimit() {
    TEST_CASE("eviction under limit");

    // Nothing to do while the cache fits.
    CHECK(evictionCount(500, 1000, 10) == 0, "a cache under its limit evicts nothing");
    CHECK(evictionCount(1000, 1000, 10) == 0, "a cache exactly at its limit evicts nothing");
}

void testEvictionOverLimit() {
    TEST_CASE("eviction over limit");

    // 10 entries averaging 10 bytes, 50 bytes over: 5 entries' worth, plus
    // one so the run always makes progress.
    CHECK(evictionCount(100, 50, 10) == 6, "eviction scales the overshoot by average entry size");

    // A small overshoot still evicts at least one entry.
    CHECK(evictionCount(101, 100, 10) == 1, "a one-byte overshoot evicts one entry");

    CHECK(evictionCount(1000, 500, 4) == 3, "eviction rounds up to clear the excess");
}

void testEvictionBounds() {
    TEST_CASE("eviction bounds");

    // Never ask to delete more rows than exist.
    CHECK(evictionCount(100, 0, 3) == 3, "eviction is capped at the entry count");
    CHECK(evictionCount(1000000, 1, 2) == 2, "a wildly oversized cache still caps at the entry count");

    // Degenerate inputs must not divide by zero or return nonsense.
    CHECK(evictionCount(100, 50, 0) == 0, "an empty cache evicts nothing");
    CHECK(evictionCount(0, 0, 5) == 0, "a zero-size cache evicts nothing");
    CHECK(evictionCount(-5, 10, 5) == 0, "a nonsense size evicts nothing");
}

void testPruneCutoff() {
    TEST_CASE("prune cutoff");

    const int64_t now = 1000000000;

    CHECK(pruneCutoffTimestamp(now, 1) == now - 86400, "one day back is 86400 seconds");
    CHECK(pruneCutoffTimestamp(now, 180) == now - 180LL * 86400, "the default retention is 180 days");
    CHECK(pruneCutoffTimestamp(now, 0) == now, "zero days expires everything up to now");

    // Long retentions must not overflow into the future.
    CHECK(pruneCutoffTimestamp(now, 36500) < now, "a hundred-year retention still points backwards");
}

void testDaysSince() {
    TEST_CASE("days since");

    const int64_t now = 1000000000;

    CHECK_NEAR(daysSince(now, now), 0.0, 1e-9, "just accessed is zero days old");
    CHECK_NEAR(daysSince(now, now - 86400), 1.0, 1e-9, "a day ago is one day old");
    CHECK_NEAR(daysSince(now, now - 43200), 0.5, 1e-9, "half a day reports fractionally");
    CHECK_NEAR(daysSince(now, now - 180LL * 86400), 180.0, 1e-6, "a long-idle entry reports its age");
}

void testCacheKeyInput() {
    TEST_CASE("cache key input");

    std::string key = cacheKeyInput("/music/track.flac", 0, 12345, 67890);
    CHECK(key == "/music/track.flac|0|12345|67890", "key concatenates track identity and file facts");

    // Each field must actually change the key, or a re-encoded file would
    // keep serving a stale waveform.
    CHECK(cacheKeyInput("/a.flac", 0, 100, 200) != cacheKeyInput("/b.flac", 0, 100, 200),
          "a different path yields a different key");
    CHECK(cacheKeyInput("/a.flac", 0, 100, 200) != cacheKeyInput("/a.flac", 1, 100, 200),
          "a different subsong yields a different key");
    CHECK(cacheKeyInput("/a.flac", 0, 100, 200) != cacheKeyInput("/a.flac", 0, 101, 200),
          "a resized file yields a different key");
    CHECK(cacheKeyInput("/a.flac", 0, 100, 200) != cacheKeyInput("/a.flac", 0, 100, 201),
          "a re-stamped file yields a different key");

    // Same track, same file facts: the key must be stable across calls, or
    // nothing would ever hit the cache.
    CHECK(cacheKeyInput("/a.flac", 2, 100, 200) == cacheKeyInput("/a.flac", 2, 100, 200),
          "identical inputs yield an identical key");
}

} // namespace

int main() {
    testSizeConversion();
    testEvictionUnderLimit();
    testEvictionOverLimit();
    testEvictionBounds();
    testPruneCutoff();
    testDaysSince();
    testCacheKeyInput();
    return testsupport::summarize("CachePolicyTests");
}
