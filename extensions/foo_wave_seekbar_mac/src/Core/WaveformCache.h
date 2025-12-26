//
//  WaveformCache.h
//  foo_wave_seekbar_mac
//
//  SQLite-based persistent cache for waveform data
//

#pragma once

#include "WaveformData.h"
#include "../fb2k_sdk.h"
#include <sqlite3.h>
#include <mutex>
#include <string>

class WaveformCache {
public:
    WaveformCache();
    ~WaveformCache();

    // Initialize cache (creates database if needed)
    bool initialize();

    // Close database connection
    void close();

    // Check if waveform exists for track
    bool hasWaveform(const metadb_handle_ptr& track) const;

    // Get cached waveform (returns nullopt if not cached)
    std::optional<WaveformData> getWaveform(const metadb_handle_ptr& track) const;

    // Store waveform in cache
    bool storeWaveform(const metadb_handle_ptr& track, const WaveformData& waveform);

    // Remove waveform from cache
    bool removeWaveform(const metadb_handle_ptr& track);

    // Clear entire cache
    bool clearCache();

    // Prune old entries (by access time)
    size_t pruneOldEntries(int maxAgeDays);

    // Enforce size limit (removes oldest entries first)
    size_t enforceSizeLimit(size_t maxSizeMB);

    // Get cache statistics
    struct CacheStats {
        size_t entryCount = 0;
        size_t totalSizeBytes = 0;
        double oldestAccessDays = 0;
    };
    CacheStats getStats() const;

private:
    // Generate cache key from track
    std::string generateCacheKey(const metadb_handle_ptr& track) const;

    // Database path
    std::string getDatabasePath() const;

    // Create tables if needed
    bool createTables();

    // Update access time for entry
    void touchEntry(const std::string& key) const;

    sqlite3* m_db = nullptr;
    mutable std::mutex m_mutex;
    bool m_initialized = false;
};

// Singleton accessor
WaveformCache& getWaveformCache();
