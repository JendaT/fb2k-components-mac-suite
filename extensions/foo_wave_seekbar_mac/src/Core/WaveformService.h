//
//  WaveformService.h
//  foo_wave_seekbar_mac
//
//  Coordination service for waveform scanning and caching
//

#pragma once

#include "WaveformData.h"
#include "WaveformScanner.h"
#include "WaveformCache.h"
#include "../fb2k_sdk.h"
#include <functional>
#include <vector>
#include <mutex>

// Callback for waveform availability
using WaveformReadyCallback = std::function<void(const metadb_handle_ptr&, const WaveformData&)>;

// Waveform service singleton
class WaveformService {
public:
    WaveformService();
    ~WaveformService();

    // Initialize service (call on startup)
    void initialize();

    // Shutdown service (call on exit)
    void shutdown();

    // Request waveform for a track
    // If cached, callback is invoked immediately
    // Otherwise, scans asynchronously and invokes callback when ready
    void requestWaveform(const metadb_handle_ptr& track, WaveformReadyCallback callback);

    // Cancel pending request for track
    void cancelRequest(const metadb_handle_ptr& track);

    // Cancel all pending requests
    void cancelAllRequests();

    // Get cached waveform (returns nullopt if not cached)
    std::optional<WaveformData> getCachedWaveform(const metadb_handle_ptr& track);

    // Register for waveform ready notifications
    using WaveformListener = std::function<void(const metadb_handle_ptr&, const WaveformData*)>;
    void addListener(WaveformListener listener);
    void removeAllListeners();

    // Cache management
    void pruneCache();
    void clearCache();

private:
    // Notify all listeners
    void notifyListeners(const metadb_handle_ptr& track, const WaveformData* waveform);

    WaveformScanner& m_scanner;
    WaveformCache& m_cache;

    std::vector<WaveformListener> m_listeners;
    std::mutex m_listenerMutex;

    metadb_handle_ptr m_pendingTrack;
    std::mutex m_pendingMutex;

    bool m_initialized = false;
};

// Singleton accessor
WaveformService& getWaveformService();
