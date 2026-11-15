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

    // Fine detail for deep zoom, stored beside the waveform under its key
    std::optional<WaveformDetail> getDetail(const metadb_handle_ptr& track) const;
    bool storeDetail(const metadb_handle_ptr& track, const WaveformDetail& detail);

    // Remove waveform (and its detail) from cache
    bool removeWaveform(const metadb_handle_ptr& track);

    // Clear entire cache
    bool clearCache();

    // Remove the entries of local files that no longer exist (see
    // waveseek::MissingFileCheck). Slow on a network share: call it off the
    // main thread. The file checks run without the lock.
    struct MissingFilesResult {
        size_t entriesRemoved = 0;
        size_t bytesRemoved = 0;            // waveforms and their detail
    };
    MissingFilesResult removeMissingFiles();

    // Prune old entries (by access time)
    size_t pruneOldEntries(int maxAgeDays);

    // Enforce size limit over waveforms and detail together: the oldest
    // detail goes first (it is the bulk, and optional), then the oldest
    // waveforms
    size_t enforceSizeLimit(size_t maxSizeMB);

    // Get cache statistics
    struct CacheStats {
        size_t entryCount = 0;
        size_t totalSizeBytes = 0;          // waveforms and detail
        size_t detailCount = 0;
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

    // Prepare all cached statements
    bool prepareStatements();

    // Finalize all cached statements
    void finalizeStatements();

    // Reset all cached statements: VACUUM fails while one is left on a row;
    // caller holds m_mutex
    void resetStatements();

    sqlite3* m_db = nullptr;
    mutable std::mutex m_mutex;
    bool m_initialized = false;

    // Prepared statements (mutable for const methods like getWaveform)
    mutable sqlite3_stmt* m_stmtHas = nullptr;
    mutable sqlite3_stmt* m_stmtGet = nullptr;
    mutable sqlite3_stmt* m_stmtStore = nullptr;
    mutable sqlite3_stmt* m_stmtRemove = nullptr;
    mutable sqlite3_stmt* m_stmtTouch = nullptr;
    mutable sqlite3_stmt* m_stmtPrune = nullptr;
    mutable sqlite3_stmt* m_stmtGetDetail = nullptr;
    mutable sqlite3_stmt* m_stmtStoreDetail = nullptr;
    mutable sqlite3_stmt* m_stmtTouchDetail = nullptr;

    // Single value of a query (0 when it fails); caller holds m_mutex
    sqlite3_int64 scalar(const char* sql) const;
    // Detail whose waveform is gone; caller holds m_mutex
    void deleteOrphanedDetail();
};

// Singleton accessor
WaveformCache& getWaveformCache();
