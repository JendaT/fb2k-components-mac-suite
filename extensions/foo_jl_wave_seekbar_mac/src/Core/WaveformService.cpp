//
//  WaveformService.cpp
//  foo_wave_seekbar_mac
//
//  Coordination service for waveform scanning and caching
//

#include "WaveformService.h"
#include "WaveformConfig.h"
#include "ConfigHelper.h"
#include <dispatch/dispatch.h>

// Singleton instance
static WaveformService g_service;

WaveformService& getWaveformService() {
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

    // Update pending track
    {
        std::lock_guard<std::mutex> lock(m_pendingMutex);
        m_pendingTrack = track;
    }

    // Scan asynchronously
    m_scanner.scanAsync(track, [this, track, callback](std::optional<WaveformData> result, const char* error) {
        // Check if this is still the pending track
        {
            std::lock_guard<std::mutex> lock(m_pendingMutex);
            if (!m_pendingTrack.is_valid() || m_pendingTrack->get_location() != track->get_location()) {
                return;  // Track changed, ignore result
            }
            m_pendingTrack.release();
        }

        if (result) {
            // Store in cache
            m_cache.storeWaveform(track, *result);

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

void WaveformService::addListener(WaveformListener listener) {
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    m_listeners.push_back(std::move(listener));
}

void WaveformService::removeAllListeners() {
    std::lock_guard<std::mutex> lock(m_listenerMutex);
    m_listeners.clear();
}

void WaveformService::notifyListeners(const metadb_handle_ptr& track, const WaveformData* waveform) {
    std::lock_guard<std::mutex> lock(m_listenerMutex);

    for (const auto& listener : m_listeners) {
        if (listener) {
            listener(track, waveform);
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
