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
#include <mutex>

// Forward declaration for Objective-C compatibility
#ifdef __OBJC__
@class WaveformScanOperation;
#else
typedef void* WaveformScanOperation;
#endif

// Scan result callback: the waveform, and its fine detail when that was
// asked for and could be gathered (null otherwise)
using WaveformScanCallback = std::function<void(std::optional<WaveformData>,
                                                std::shared_ptr<const WaveformDetail> detail, const char* error)>;

// Scanner for extracting waveform data from audio files
class WaveformScanner {
public:
    WaveformScanner();
    ~WaveformScanner();

    // Start async scan of a track, gathering the fine detail too with `detail`
    // Callback is invoked on main thread when complete
    void scanAsync(const metadb_handle_ptr& track, bool detail, WaveformScanCallback callback);

    // Cancel any pending scan
    void cancel();

    // Check if a scan is in progress
    bool isScanning() const;

    // Synchronous scan (for testing)
    std::optional<WaveformData> scanSync(const metadb_handle_ptr& track, abort_callback& abort);

private:
    // Internal scan implementation; `detail` non-null gathers the fine detail into it
    std::optional<WaveformData> performScan(const metadb_handle_ptr& track, abort_callback& abort,
                                            std::optional<WaveformDetail>* detail = nullptr);

    // Atomic state
    std::atomic<bool> m_scanning{false};
    std::atomic<uint64_t> m_generation{0};  // Increments per scan to detect stale results

    // Each scan owns its abort object for its whole lifetime. A shared member
    // would let a newly started scan reset the flag an older, still-running scan
    // is about to observe - leaving two decoders racing on one abort_callback.
    std::mutex m_abortMutex;
    std::shared_ptr<abort_callback_impl> m_currentAbort;
};

// Singleton accessor
WaveformScanner& getWaveformScanner();
