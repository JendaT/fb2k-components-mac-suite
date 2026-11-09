//
//  WaveformService.cpp
//  foo_wave_seekbar_mac
//
//  Coordination service for waveform scanning and caching
//

#include "WaveformService.h"
#include "WaveformConfig.h"
#include "ConfigHelper.h"
#include <algorithm>
#include <dispatch/dispatch.h>

// Construct-on-first-use singleton to avoid static initialization order issues
WaveformService& getWaveformService() {
    static WaveformService g_service;
    return g_service;
}

WaveformService::WaveformService()
    : m_scanner(getWaveformScanner())
    , m_cache(getWaveformCache())
{
}

WaveformService::~WaveformService() {
    shutdown();
}

void WaveformService::initialize() {
    if (m_initialized) return;

    // Initialize cache
    if (!m_cache.initialize()) {
        console::error("[WaveSeek] Failed to initialize waveform cache");
    }

    // Prune old entries on startup
    pruneCache();

    m_initialized = true;
}

void WaveformService::shutdown() {
    if (!m_initialized) return;

    // Cancel any pending scans
    cancelAllRequests();

    // Close cache
    m_cache.close();

    m_initialized = false;
}

void WaveformService::requestWaveform(const metadb_handle_ptr& track, WaveformReadyCallback callback) {
    if (!track.is_valid()) {
        if (callback) {
            callback(track, WaveformData());
        }
        return;
    }
    // Check cache first
    auto cached = m_cache.getWaveform(track);
    if (cached) {
        if (callback) {
            callback(track, *cached);
        }
        notifyListeners(track, &(*cached));
        return;
    }

    // Update pending track (serialized with scan completion check)
    {
        std::lock_guard<std::mutex> lock(m_pendingMutex);

        // Double-check cache under lock to prevent race with concurrent store
        auto rechecked = m_cache.getWaveform(track);
        if (rechecked) {
            if (callback) {
                callback(track, *rechecked);
            }
            notifyListeners(track, &(*rechecked));
            return;
        }

        // A second seekbar, a layout change or the watchdog asking again must
        // not restart a long scan from the beginning
        if (!callback && isScanningLocked(track)) {
            return;
        }

        m_pendingTrack = track;
    }

    // Scan asynchronously; with the zoom_detail option the same pass gathers the detail
    m_scanner.scanAsync(track, detailEnabled(), [this, track, callback](std::optional<WaveformData> result,
                                                                       std::shared_ptr<const WaveformDetail> detail,
                                                                       const char* error) {
        // Clear the pending slot if this result is the one it was waiting for.
        // The result is delivered either way: listeners filter by track themselves,
        // and dropping it here used to strand the UI in its "analyzing" state
        // forever when the pending track was replaced mid-scan (layout reload).
        {
            std::lock_guard<std::mutex> lock(m_pendingMutex);
            if (m_pendingTrack.is_valid() && m_pendingTrack->get_location() == track->get_location()) {
                m_pendingTrack.release();
            }
        }

        if (result) {
            // Store in cache
            m_cache.storeWaveform(track, *result);

            // The detail first, so a listener that asks for it on the
            // waveform already holds it instead of starting a rescan
            if (detail) {
                notifyDetail(track, detail);
                storeDetail(track, detail);
            }

            // Invoke callback
            if (callback) {
                callback(track, *result);
            }

            // Notify listeners
            notifyListeners(track, &(*result));
        } else {
            if (error) {
                pfc::string_formatter msg;
                msg << "[WaveSeek] " << error;
                console::warning(msg.c_str());
            }

            // Notify with null waveform
            if (callback) {
                callback(track, WaveformData());
            }
            notifyListeners(track, nullptr);
        }
    });
}

bool WaveformService::detailEnabled() {
    using namespace waveform_config;
    return getConfigBool(kKeyZoomEnabled, kDefaultZoomEnabled) && getConfigBool(kKeyZoomDetail, kDefaultZoomDetail);
}

void WaveformService::requestDetail(const metadb_handle_ptr& track) {
    if (!track.is_valid() || !detailEnabled()) return;

    // The blob is up to a few MB: load it off the main thread
    metadb_handle_ptr handle = track;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::optional<WaveformDetail> cached = m_cache.getDetail(handle);
        std::shared_ptr<const WaveformDetail> detail =
            cached ? std::make_shared<const WaveformDetail>(std::move(*cached)) : nullptr;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (detail) {
                notifyDetail(handle, detail);
                return;
            }

            // Rescan only while nothing else is scanning: a track that
            // starts playing takes over (its request cancels this scan)
            {
                std::lock_guard<std::mutex> lock(m_pendingMutex);
                if (m_scanner.isScanning() || m_pendingTrack.is_valid()) return;
                m_pendingTrack = handle;
            }
            m_scanner.scanAsync(handle, true, [this, handle](std::optional<WaveformData> result,
                                                             std::shared_ptr<const WaveformDetail> scanned,
                                                             const char*) {
                {
                    std::lock_guard<std::mutex> lock(m_pendingMutex);
                    if (m_pendingTrack.is_valid() && m_pendingTrack->get_location() == handle->get_location()) {
                        m_pendingTrack.release();
                    }
                }
                // The waveform is cached and shown already; only the detail is new
                if (result && scanned) {
                    notifyDetail(handle, scanned);
                    storeDetail(handle, scanned);
                }
            });
        });
    });
}

void WaveformService::storeDetail(const metadb_handle_ptr& track, std::shared_ptr<const WaveformDetail> detail) {
    using namespace waveform_config;
    if (!detail) return;
    // Compressing a few MB and writing it takes 30-150 ms: off the main thread
    const int maxSizeMB = static_cast<int>(getConfigInt(kKeyCacheSizeMB, kDefaultCacheSizeMB));
    metadb_handle_ptr handle = track;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        m_cache.storeDetail(handle, *detail);
        if (maxSizeMB > 0) m_cache.enforceSizeLimit(static_cast<size_t>(maxSizeMB));
    });
}

ListenerId WaveformService::addDetailListener(DetailListener listener) {
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    ListenerId id = m_nextListenerId++;
    m_detailListeners.push_back({id, std::move(listener)});
    return id;
}

void WaveformService::removeDetailListener(ListenerId id) {
    if (id == InvalidListenerId) return;
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    m_detailListeners.erase(
        std::remove_if(m_detailListeners.begin(), m_detailListeners.end(),
            [id](const DetailListenerEntry& entry) { return entry.id == id; }),
        m_detailListeners.end());
}

void WaveformService::notifyDetail(const metadb_handle_ptr& track, std::shared_ptr<const WaveformDetail> detail) {
    std::vector<DetailListenerEntry> snapshot;
    {
        std::lock_guard<std::mutex> lock(m_listenerMutex);
        snapshot = m_detailListeners;
    }
    for (const auto& entry : snapshot) {
        if (entry.callback) entry.callback(track, detail);
    }
}

bool WaveformService::isScanning(const metadb_handle_ptr& track) {
    std::lock_guard<std::mutex> lock(m_pendingMutex);
    return isScanningLocked(track);
}

bool WaveformService::isScanningLocked(const metadb_handle_ptr& track) const {
    return track.is_valid() && m_scanner.isScanning() && m_pendingTrack.is_valid() &&
           m_pendingTrack->get_location() == track->get_location();
}

void WaveformService::cancelRequest(const metadb_handle_ptr& track) {
    std::lock_guard<std::mutex> lock(m_pendingMutex);

    if (m_pendingTrack.is_valid() && track.is_valid() &&
        m_pendingTrack->get_location() == track->get_location()) {
        m_scanner.cancel();
        m_pendingTrack.release();
    }
}

void WaveformService::cancelAllRequests() {
    std::lock_guard<std::mutex> lock(m_pendingMutex);
    m_scanner.cancel();
    m_pendingTrack.release();
}

std::optional<WaveformData> WaveformService::getCachedWaveform(const metadb_handle_ptr& track) {
    return m_cache.getWaveform(track);
}

ListenerId WaveformService::addListener(WaveformListener listener) {
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    ListenerId id = m_nextListenerId++;
    m_listeners.push_back({id, std::move(listener)});
    return id;
}

void WaveformService::removeListener(ListenerId id) {
    if (id == InvalidListenerId) return;

    std::lock_guard<std::mutex> lock(m_listenerMutex);
    m_listeners.erase(
        std::remove_if(m_listeners.begin(), m_listeners.end(),
            [id](const ListenerEntry& entry) { return entry.id == id; }),
        m_listeners.end()
    );
}

void WaveformService::removeAllListeners() {
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    m_listeners.clear();
    m_detailListeners.clear();
}

void WaveformService::notifyListeners(const metadb_handle_ptr& track, const WaveformData* waveform) {
    // Snapshot listeners under lock, then invoke outside the lock to prevent deadlocks
    std::vector<ListenerEntry> snapshot;
    {
        std::lock_guard<std::mutex> lock(m_listenerMutex);
        snapshot = m_listeners;
    }

    for (const auto& entry : snapshot) {
        if (entry.callback) {
            entry.callback(track, waveform);
        }
    }
}

void WaveformService::pruneCache() {
    using namespace waveform_config;
    // Get config values via configStore
    int retentionDays = static_cast<int>(getConfigInt(kKeyCacheRetentionDays, kDefaultCacheRetentionDays));
    int maxSizeMB = static_cast<int>(getConfigInt(kKeyCacheSizeMB, kDefaultCacheSizeMB));

    // Prune old entries
    if (retentionDays > 0) {
        m_cache.pruneOldEntries(retentionDays);
    }

    // Enforce size limit
    if (maxSizeMB > 0) {
        m_cache.enforceSizeLimit(static_cast<size_t>(maxSizeMB));
    }
}

void WaveformService::clearCache() {
    m_cache.clearCache();
}

WaveformCache::MissingFilesResult WaveformService::removeMissingFiles() {
    return m_cache.removeMissingFiles();
}

WaveformService::CacheStats WaveformService::getCacheStats() const {
    auto raw = m_cache.getStats();
    return {raw.entryCount, raw.totalSizeBytes, raw.detailCount, raw.oldestAccessDays};
}
