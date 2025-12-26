//
//  WaveformScanner.h
//  foo_wave_seekbar_mac
//
//  Async audio scanning with peak extraction
//

#pragma once

#include "WaveformData.h"
#include "../fb2k_sdk.h"
#include <functional>
#include <memory>
#include <atomic>

// Forward declaration for Objective-C compatibility
#ifdef __OBJC__
@class WaveformScanOperation;
#else
typedef void* WaveformScanOperation;
#endif

// Scan result callback
using WaveformScanCallback = std::function<void(std::optional<WaveformData>, const char* error)>;

// Scanner for extracting waveform data from audio files
class WaveformScanner {
public:
    WaveformScanner();
    ~WaveformScanner();

    // Start async scan of a track
    // Callback is invoked on main thread when complete
    void scanAsync(const metadb_handle_ptr& track, WaveformScanCallback callback);

    // Cancel any pending scan
    void cancel();

    // Check if a scan is in progress
    bool isScanning() const;

    // Synchronous scan (for testing)
    std::optional<WaveformData> scanSync(const metadb_handle_ptr& track, abort_callback& abort);

private:
    // Internal scan implementation
    std::optional<WaveformData> performScan(const metadb_handle_ptr& track, abort_callback& abort);

    // Atomic state
    std::atomic<bool> m_scanning{false};
    std::atomic<bool> m_cancelRequested{false};

    // Current abort callback for cancellation
    abort_callback_impl m_abort;
};

// Singleton accessor
WaveformScanner& getWaveformScanner();
