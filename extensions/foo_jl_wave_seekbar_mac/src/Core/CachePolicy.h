//
//  CachePolicy.h
//  foo_wave_seekbar_mac
//
//  Cache retention arithmetic, separated from the SQLite statements that
//  execute it.
//
//  Extracted from WaveformCache so the eviction and expiry rules can be
//  unit-tested without a database file. Header-only and SDK-free; the cache
//  keeps the queries, this decides what to ask for.
//

#pragma once

#include <algorithm>
#include <cstdint>
#include <string>

namespace waveseek {

constexpr int64_t kSecondsPerDay = 24 * 60 * 60;

inline int64_t bytesFromMegabytes(int64_t megabytes) {
    return megabytes * 1024 * 1024;
}

// Entries last accessed before this timestamp have expired.
inline int64_t pruneCutoffTimestamp(int64_t nowSeconds, int maxAgeDays) {
    return nowSeconds - static_cast<int64_t>(maxAgeDays) * kSecondsPerDay;
}

inline double daysSince(int64_t nowSeconds, int64_t timestampSeconds) {
    return static_cast<double>(nowSeconds - timestampSeconds) / static_cast<double>(kSecondsPerDay);
}

// How many of the least-recently-used entries to drop to get back under the
// size limit. Entry sizes are not known individually here, so this scales the
// overshoot by the average entry size and rounds up - deliberately deleting
// slightly more than strictly needed, so a run always makes progress instead
// of leaving the cache a few bytes over and re-triggering next time.
inline int64_t evictionCount(int64_t currentSizeBytes, int64_t maxSizeBytes, int64_t entryCount) {
    if (currentSizeBytes <= maxSizeBytes || entryCount <= 0 || currentSizeBytes <= 0) {
        return 0;
    }
    int64_t excess = currentSizeBytes - maxSizeBytes;
    int64_t count = (excess * entryCount) / currentSizeBytes + 1;
    return std::min(count, entryCount);
}

// Identity of a cached waveform: the track, plus the file facts that mean the
// audio changed underneath it. Hashed by the caller.
//
// The '|' separator is ambiguous for paths that themselves contain '|' - a
// collision needs the neighbouring fields to compensate exactly, so it is
// vanishingly unlikely, and changing the separator would invalidate every
// existing cache entry. Kept as-is deliberately.
inline std::string cacheKeyInput(const std::string& path, uint32_t subsong,
                                 int64_t fileSize, int64_t fileTimestamp) {
    return path + "|" + std::to_string(subsong) + "|" +
           std::to_string(fileSize) + "|" + std::to_string(fileTimestamp);
}

} // namespace waveseek
