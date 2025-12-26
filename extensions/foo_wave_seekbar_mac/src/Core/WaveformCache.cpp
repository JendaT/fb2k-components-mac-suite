//
//  WaveformCache.cpp
//  foo_wave_seekbar_mac
//
//  SQLite-based persistent cache for waveform data
//

#include "WaveformCache.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <ctime>

// Singleton instance
static WaveformCache g_cache;

WaveformCache& getWaveformCache() {
    return g_cache;
}

WaveformCache::WaveformCache() = default;

WaveformCache::~WaveformCache() {
    close();
}

std::string WaveformCache::getDatabasePath() const {
    // Use foobar2000's profile directory
    pfc::string8 profilePath;
    try {
        profilePath = core_api::get_profile_path();
    } catch (...) {
        // Fallback to temp directory
        return "/tmp/foo_wave_seekbar_cache.db";
    }

    // Convert file:// URL to path if needed
    std::string path(profilePath.c_str());
    if (path.find("file://") == 0) {
        path = path.substr(7);
    }

    // Create cache directory if needed
    std::string cacheDir = path + "/waveform_cache";
    mkdir(cacheDir.c_str(), 0755);

    return cacheDir + "/waveforms.db";
}

bool WaveformCache::initialize() {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_initialized) {
        return true;
    }

    std::string dbPath = getDatabasePath();

    // Open database with WAL mode
    int rc = sqlite3_open_v2(dbPath.c_str(), &m_db,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                             nullptr);

    if (rc != SQLITE_OK) {
        console::error("[WaveSeek] Failed to open cache database");
        m_db = nullptr;
        return false;
    }

    // Enable WAL mode for better concurrent performance
    sqlite3_exec(m_db, "PRAGMA journal_mode=WAL;", nullptr, nullptr, nullptr);
    sqlite3_exec(m_db, "PRAGMA synchronous=NORMAL;", nullptr, nullptr, nullptr);
    sqlite3_exec(m_db, "PRAGMA cache_size=-2000;", nullptr, nullptr, nullptr); // 2MB cache

    if (!createTables()) {
        close();
        return false;
    }

    m_initialized = true;
    return true;
}

bool WaveformCache::createTables() {
    const char* sql = R"(
        CREATE TABLE IF NOT EXISTS waveforms (
            cache_key TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            subsong INTEGER NOT NULL,
            channels INTEGER NOT NULL,
            sample_rate INTEGER NOT NULL,
            duration REAL NOT NULL,
            data BLOB NOT NULL,
            size_bytes INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            accessed_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_waveforms_accessed ON waveforms(accessed_at);
        CREATE INDEX IF NOT EXISTS idx_waveforms_path ON waveforms(path, subsong);
    )";

    char* errMsg = nullptr;
    int rc = sqlite3_exec(m_db, sql, nullptr, nullptr, &errMsg);

    if (rc != SQLITE_OK) {
        pfc::string_formatter msg;
        msg << "[WaveSeek] Failed to create tables: " << (errMsg ? errMsg : "unknown error");
        console::error(msg.c_str());
        sqlite3_free(errMsg);
        return false;
    }

    return true;
}

void WaveformCache::close() {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (m_db) {
        sqlite3_close(m_db);
        m_db = nullptr;
    }
    m_initialized = false;
}

std::string WaveformCache::generateCacheKey(const metadb_handle_ptr& track) const {
    if (!track.is_valid()) {
        return "";
    }

    // Build key from path + subsong + file stats
    pfc::string8 path = track->get_path();
    t_uint32 subsong = track->get_subsong_index();

    // Get file stats if available
    t_filestats stats = track->get_filestats();

    // Create hash input
    pfc::string_formatter keyInput;
    keyInput << path.c_str() << "|" << subsong << "|"
             << stats.m_size << "|" << stats.m_timestamp;

    // SHA-256 hash
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(keyInput.c_str(), static_cast<CC_LONG>(keyInput.length()), hash);

    // Convert to hex string
    char hexStr[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        snprintf(hexStr + (i * 2), 3, "%02x", hash[i]);
    }

    return std::string(hexStr);
}

bool WaveformCache::hasWaveform(const metadb_handle_ptr& track) const {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || !track.is_valid()) {
        return false;
    }

    std::string key = generateCacheKey(track);
    if (key.empty()) {
        return false;
    }

    const char* sql = "SELECT 1 FROM waveforms WHERE cache_key = ? LIMIT 1";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        return false;
    }

    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);

    bool exists = (sqlite3_step(stmt) == SQLITE_ROW);
    sqlite3_finalize(stmt);

    return exists;
}

std::optional<WaveformData> WaveformCache::getWaveform(const metadb_handle_ptr& track) const {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || !track.is_valid()) {
        return std::nullopt;
    }

    std::string key = generateCacheKey(track);
    if (key.empty()) {
        return std::nullopt;
    }

    const char* sql = "SELECT data FROM waveforms WHERE cache_key = ?";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        return std::nullopt;
    }

    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);

    std::optional<WaveformData> result;

    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const void* blob = sqlite3_column_blob(stmt, 0);
        int blobSize = sqlite3_column_bytes(stmt, 0);

        if (blob && blobSize > 0) {
            result = WaveformData::decompress(
                static_cast<const uint8_t*>(blob),
                static_cast<size_t>(blobSize)
            );

            if (result) {
                // Update access time
                touchEntry(key);
            }
        }
    }

    sqlite3_finalize(stmt);
    return result;
}

void WaveformCache::touchEntry(const std::string& key) const {
    const char* sql = "UPDATE waveforms SET accessed_at = ? WHERE cache_key = ?";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, static_cast<sqlite3_int64>(std::time(nullptr)));
        sqlite3_bind_text(stmt, 2, key.c_str(), -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

bool WaveformCache::storeWaveform(const metadb_handle_ptr& track, const WaveformData& waveform) {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || !track.is_valid()) {
        return false;
    }

    std::string key = generateCacheKey(track);
    if (key.empty()) {
        return false;
    }

    // Compress waveform data
    std::vector<uint8_t> compressed = waveform.compress();
    if (compressed.empty()) {
        return false;
    }

    const char* sql = R"(
        INSERT OR REPLACE INTO waveforms
        (cache_key, path, subsong, channels, sample_rate, duration, data, size_bytes, created_at, accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    )";

    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        return false;
    }

    pfc::string8 path = track->get_path();
    t_uint32 subsong = track->get_subsong_index();
    sqlite3_int64 now = static_cast<sqlite3_int64>(std::time(nullptr));

    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, path.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 3, static_cast<int>(subsong));
    sqlite3_bind_int(stmt, 4, static_cast<int>(waveform.channelCount));
    sqlite3_bind_int(stmt, 5, static_cast<int>(waveform.sampleRate));
    sqlite3_bind_double(stmt, 6, waveform.duration);
    sqlite3_bind_blob(stmt, 7, compressed.data(), static_cast<int>(compressed.size()), SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 8, static_cast<sqlite3_int64>(compressed.size()));
    sqlite3_bind_int64(stmt, 9, now);
    sqlite3_bind_int64(stmt, 10, now);

    bool success = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);

    return success;
}

bool WaveformCache::removeWaveform(const metadb_handle_ptr& track) {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || !track.is_valid()) {
        return false;
    }

    std::string key = generateCacheKey(track);
    if (key.empty()) {
        return false;
    }

    const char* sql = "DELETE FROM waveforms WHERE cache_key = ?";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        return false;
    }

    sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_STATIC);

    bool success = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);

    return success;
}

bool WaveformCache::clearCache() {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db) {
        return false;
    }

    char* errMsg = nullptr;
    int rc = sqlite3_exec(m_db, "DELETE FROM waveforms", nullptr, nullptr, &errMsg);

    if (rc != SQLITE_OK) {
        sqlite3_free(errMsg);
        return false;
    }

    // Vacuum to reclaim space
    sqlite3_exec(m_db, "VACUUM", nullptr, nullptr, nullptr);

    return true;
}

size_t WaveformCache::pruneOldEntries(int maxAgeDays) {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || maxAgeDays <= 0) {
        return 0;
    }

    sqlite3_int64 cutoff = static_cast<sqlite3_int64>(std::time(nullptr)) - (maxAgeDays * 24 * 60 * 60);

    const char* sql = "DELETE FROM waveforms WHERE accessed_at < ?";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        return 0;
    }

    sqlite3_bind_int64(stmt, 1, cutoff);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    int changes = sqlite3_changes(m_db);
    return static_cast<size_t>(changes > 0 ? changes : 0);
}

size_t WaveformCache::enforceSizeLimit(size_t maxSizeMB) {
    std::lock_guard<std::mutex> lock(m_mutex);

    if (!m_db || maxSizeMB == 0) {
        return 0;
    }

    // Get current size
    const char* sizeSql = "SELECT SUM(size_bytes) FROM waveforms";
    sqlite3_stmt* stmt = nullptr;
    sqlite3_int64 currentSize = 0;

    if (sqlite3_prepare_v2(m_db, sizeSql, -1, &stmt, nullptr) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            currentSize = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_int64 maxSizeBytes = static_cast<sqlite3_int64>(maxSizeMB) * 1024 * 1024;
    if (currentSize <= maxSizeBytes) {
        return 0;
    }

    // Delete oldest entries until under limit
    size_t deleted = 0;
    while (currentSize > maxSizeBytes) {
        const char* deleteSql = R"(
            DELETE FROM waveforms WHERE cache_key IN (
                SELECT cache_key FROM waveforms ORDER BY accessed_at ASC LIMIT 10
            )
        )";

        if (sqlite3_exec(m_db, deleteSql, nullptr, nullptr, nullptr) != SQLITE_OK) {
            break;
        }

        int changes = sqlite3_changes(m_db);
        if (changes <= 0) break;

        deleted += static_cast<size_t>(changes);

        // Re-check size
        if (sqlite3_prepare_v2(m_db, sizeSql, -1, &stmt, nullptr) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                currentSize = sqlite3_column_int64(stmt, 0);
            }
            sqlite3_finalize(stmt);
        }
    }

    return deleted;
}

WaveformCache::CacheStats WaveformCache::getStats() const {
    std::lock_guard<std::mutex> lock(m_mutex);

    CacheStats stats;

    if (!m_db) {
        return stats;
    }

    // Count and total size
    const char* countSql = "SELECT COUNT(*), COALESCE(SUM(size_bytes), 0) FROM waveforms";
    sqlite3_stmt* stmt = nullptr;

    if (sqlite3_prepare_v2(m_db, countSql, -1, &stmt, nullptr) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            stats.entryCount = static_cast<size_t>(sqlite3_column_int64(stmt, 0));
            stats.totalSizeBytes = static_cast<size_t>(sqlite3_column_int64(stmt, 1));
        }
        sqlite3_finalize(stmt);
    }

    // Oldest access
    const char* oldestSql = "SELECT MIN(accessed_at) FROM waveforms";

    if (sqlite3_prepare_v2(m_db, oldestSql, -1, &stmt, nullptr) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
            sqlite3_int64 oldest = sqlite3_column_int64(stmt, 0);
            sqlite3_int64 now = static_cast<sqlite3_int64>(std::time(nullptr));
            stats.oldestAccessDays = static_cast<double>(now - oldest) / (24.0 * 60.0 * 60.0);
        }
        sqlite3_finalize(stmt);
    }

    return stats;
}
