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
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
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

// --- Clear Missing Files ---------------------------------------------------
//
// Which cached tracks are gone for good. Only proof of absence removes an
// entry: anything uncertain (another scheme, an I/O error, a volume that is
// not mounted) keeps it.

// Only local files are checked; streams, services and archive members
// (http://, unpack://, ...) are kept.
inline bool isLocalFilePath(const std::string& fb2kPath) {
    return fb2kPath.compare(0, 7, "file://") == 0;
}

// stat's errno that proves the file is gone. EIO, a timeout or a permission
// error may pass, so they keep the entry.
inline bool errorMeansMissing(int error) {
    return error == ENOENT || error == ENOTDIR;
}

// "/Volumes/<name>" for a path inside a volume, else empty
inline std::string volumeRootOf(const std::string& nativePath) {
    static const std::string prefix = "/Volumes/";
    if (nativePath.size() <= prefix.size()) return {};
    for (size_t i = 0; i < prefix.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(nativePath[i])) !=
            std::tolower(static_cast<unsigned char>(prefix[i]))) {
            return {};
        }
    }
    const size_t slash = nativePath.find('/', prefix.size());
    if (slash == std::string::npos || slash == prefix.size()) return {};
    return nativePath.substr(0, slash);
}

// The verdict on native paths of local files, with the file system injected.
// A file under /Volumes/<name>/ counts as missing only while that volume is
// mounted: an unmounted share leaves no folder, or a bare folder on the
// same device as /Volumes, and every file on it would look deleted.
// Each volume is looked at once per MissingFileCheck.
class MissingFileCheck {
public:
    struct FileSystem {
        // errno of stat(path), 0 when it succeeds
        std::function<int(const std::string&)> statError;
        // st_dev of stat(path), nullopt when it fails
        std::function<std::optional<uint64_t>(const std::string&)> device;
    };

    explicit MissingFileCheck(FileSystem fs) : m_fs(std::move(fs)) {}

    bool isMissing(const std::string& nativePath) {
        if (nativePath.empty() || nativePath[0] != '/') return false;
        if (!errorMeansMissing(m_fs.statError(nativePath))) return false;
        const std::string root = volumeRootOf(nativePath);
        return root.empty() || volumeMounted(root);
    }

private:
    bool volumeMounted(const std::string& root) {
        const auto known = m_mounted.find(root);
        if (known != m_mounted.end()) return known->second;
        if (!m_volumesDevice) m_volumesDevice = m_fs.device("/Volumes");
        const auto device = m_fs.device(root);
        const bool mounted = device && *m_volumesDevice && **m_volumesDevice != *device;
        m_mounted.emplace(root, mounted);
        return mounted;
    }

    FileSystem m_fs;
    std::optional<std::optional<uint64_t>> m_volumesDevice;   // looked up once
    std::map<std::string, bool> m_mounted;                    // by volume root
};

} // namespace waveseek
