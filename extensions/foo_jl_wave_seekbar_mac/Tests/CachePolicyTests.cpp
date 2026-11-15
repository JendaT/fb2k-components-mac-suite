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

void testLocalFilePath() {
    TEST_CASE("local file path");

    CHECK(isLocalFilePath("file:///Volumes/music/a.flac"), "a file:// path is checked");
    CHECK(isLocalFilePath("file://~/Music/a.flac"), "a home-relative file:// path is checked");
    CHECK(!isLocalFilePath("https://example.com/a.mp3"), "a stream is kept");
    CHECK(!isLocalFilePath("http://example.com/a.mp3"), "a plain http stream is kept");
    CHECK(!isLocalFilePath("unpack://zip|30|file:///music/a.zip|a.flac"), "an archive member is kept");
    CHECK(!isLocalFilePath("tidal://track/123"), "a streaming service track is kept");
    CHECK(!isLocalFilePath("/music/a.flac"), "a bare path without a scheme is kept");
    CHECK(!isLocalFilePath("file:/music/a.flac"), "a malformed scheme is kept");
    CHECK(!isLocalFilePath(""), "an empty path is kept");
}

void testErrorMeansMissing() {
    TEST_CASE("error means missing");

    CHECK(errorMeansMissing(ENOENT), "no such file is missing");
    CHECK(errorMeansMissing(ENOTDIR), "a path through a non-folder is missing");
    CHECK(!errorMeansMissing(0), "a file that exists is kept");
    CHECK(!errorMeansMissing(EIO), "an I/O error is kept");
    CHECK(!errorMeansMissing(ETIMEDOUT), "a timeout is kept");
    CHECK(!errorMeansMissing(EACCES), "a permission error is kept");
    CHECK(!errorMeansMissing(EPERM), "an operation not permitted is kept");
    CHECK(!errorMeansMissing(ENAMETOOLONG), "a too long name is kept");
}

void testVolumeRoot() {
    TEST_CASE("volume root");

    CHECK(volumeRootOf("/Volumes/music/a/b.flac") == "/Volumes/music", "a file inside a volume names it");
    CHECK(volumeRootOf("/Volumes/My Disk/a.flac") == "/Volumes/My Disk", "a volume name may hold spaces");
    CHECK(volumeRootOf("/volumes/music/a.flac") == "/volumes/music", "the prefix matches in any case");
    CHECK(volumeRootOf("/Users/me/Music/a.flac").empty(), "a file outside /Volumes has no volume");
    CHECK(volumeRootOf("/Volumes/a.flac").empty(), "a file right in /Volumes has no volume");
    CHECK(volumeRootOf("/Volumes/").empty(), "/Volumes itself has no volume");
    CHECK(volumeRootOf("/Volumes//a.flac").empty(), "an empty volume name has no volume");
    CHECK(volumeRootOf("/VolumesX/music/a.flac").empty(), "a lookalike folder has no volume");
}

// A file system where the listed paths stat with the given errno (else they
// exist) and the listed folders sit on the given devices (else stat fails)
struct FakeFileSystem {
    std::map<std::string, int> errors;
    std::map<std::string, uint64_t> devices;
    std::map<std::string, int> deviceLookups;

    MissingFileCheck::FileSystem bind() {
        return {
            [this](const std::string& path) {
                const auto it = errors.find(path);
                return it == errors.end() ? 0 : it->second;
            },
            [this](const std::string& path) -> std::optional<uint64_t> {
                deviceLookups[path]++;
                const auto it = devices.find(path);
                if (it == devices.end()) return std::nullopt;
                return it->second;
            },
        };
    }
};

void testMissingOutsideVolumes() {
    TEST_CASE("missing outside /Volumes");

    FakeFileSystem fs;
    fs.errors["/Users/me/Music/gone.flac"] = ENOENT;
    fs.errors["/Users/me/Music/file.flac/x.flac"] = ENOTDIR;
    fs.errors["/Users/me/Music/locked.flac"] = EACCES;
    fs.errors["/Users/me/Music/broken.flac"] = EIO;
    MissingFileCheck check(fs.bind());

    CHECK(check.isMissing("/Users/me/Music/gone.flac"), "a deleted local file is missing");
    CHECK(check.isMissing("/Users/me/Music/file.flac/x.flac"), "a path through a file is missing");
    CHECK(!check.isMissing("/Users/me/Music/here.flac"), "a file that exists is kept");
    CHECK(!check.isMissing("/Users/me/Music/locked.flac"), "an unreadable file is kept");
    CHECK(!check.isMissing("/Users/me/Music/broken.flac"), "a file with an I/O error is kept");
    CHECK(!check.isMissing(""), "an empty path is kept");
    CHECK(!check.isMissing("relative/gone.flac"), "a relative path is kept");
    CHECK(fs.deviceLookups.empty(), "no volume is looked at outside /Volumes");
}

void testMissingOnVolumes() {
    TEST_CASE("missing on volumes");

    FakeFileSystem fs;
    fs.devices["/Volumes"] = 1;
    fs.devices["/Volumes/music"] = 7;       // a mounted share
    fs.devices["/Volumes/stale"] = 1;       // a bare folder left by an unmount
    // "/Volumes/gone" has no folder at all
    fs.errors["/Volumes/music/deleted.flac"] = ENOENT;
    fs.errors["/Volumes/music/deleted2.flac"] = ENOENT;
    fs.errors["/Volumes/music/slow.flac"] = ETIMEDOUT;
    fs.errors["/Volumes/stale/a.flac"] = ENOENT;
    fs.errors["/Volumes/gone/a.flac"] = ENOENT;
    fs.errors["/Volumes/gone/b.flac"] = ENOTDIR;
    MissingFileCheck check(fs.bind());

    CHECK(check.isMissing("/Volumes/music/deleted.flac"), "a deleted file on a mounted volume is missing");
    CHECK(check.isMissing("/Volumes/music/deleted2.flac"), "a second deleted file on it is missing too");
    CHECK(!check.isMissing("/Volumes/music/here.flac"), "a file on a mounted volume that exists is kept");
    CHECK(!check.isMissing("/Volumes/music/slow.flac"), "a timeout on a mounted volume is kept");
    CHECK(!check.isMissing("/Volumes/stale/a.flac"), "a volume that left a bare folder is not mounted");
    CHECK(!check.isMissing("/Volumes/gone/a.flac"), "a volume without a folder is not mounted");
    CHECK(!check.isMissing("/Volumes/gone/b.flac"), "every file on an unmounted volume is kept");

    CHECK(fs.deviceLookups["/Volumes/music"] == 1, "a volume is looked at once");
    CHECK(fs.deviceLookups["/Volumes/gone"] == 1, "an unmounted volume is looked at once");
    CHECK(fs.deviceLookups["/Volumes"] == 1, "/Volumes itself is looked at once");
}

void testMissingWithoutVolumesDevice() {
    TEST_CASE("missing without /Volumes device");

    // When /Volumes cannot be looked at, no volume can be told mounted
    FakeFileSystem fs;
    fs.devices["/Volumes/music"] = 7;
    fs.errors["/Volumes/music/deleted.flac"] = ENOENT;
    fs.errors["/Users/me/gone.flac"] = ENOENT;
    MissingFileCheck check(fs.bind());

    CHECK(!check.isMissing("/Volumes/music/deleted.flac"), "a volume file is kept when /Volumes fails");
    CHECK(check.isMissing("/Users/me/gone.flac"), "a file outside /Volumes is still checked");
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
    testLocalFilePath();
    testErrorMeansMissing();
    testVolumeRoot();
    testMissingOutsideVolumes();
    testMissingOnVolumes();
    testMissingWithoutVolumesDevice();
    return testsupport::summarize("CachePolicyTests");
}
