//
//  WaveformScanner.cpp
//  foo_wave_seekbar_mac
//
//  Async audio scanning with peak extraction
//

#include "WaveformScanner.h"
#include <dispatch/dispatch.h>
#include <cmath>

// Singleton instance
static WaveformScanner g_scanner;

WaveformScanner& getWaveformScanner() {
    return g_scanner;
}

WaveformScanner::WaveformScanner() = default;

WaveformScanner::~WaveformScanner() {
    cancel();
}

bool WaveformScanner::isScanning() const {
    return m_scanning.load();
}

void WaveformScanner::cancel() {
    if (m_scanning.load()) {
        m_cancelRequested.store(true);
        m_abort.abort();
    }
}

void WaveformScanner::scanAsync(const metadb_handle_ptr& track, WaveformScanCallback callback) {
    if (!track.is_valid()) {
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(std::nullopt, "Invalid track handle");
            });
        }
        return;
    }

    // Cancel any existing scan
    cancel();

    // Reset state
    m_cancelRequested.store(false);
    m_abort.reset();
    m_scanning.store(true);

    // Capture track path for the block
    pfc::string8 path = track->get_path();
    t_uint32 subsong = track->get_subsong_index();

    // Dispatch to background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::optional<WaveformData> result;
        const char* error = nullptr;

        try {
            // Re-obtain handle on background thread
            metadb_handle_ptr handle;
            metadb::get()->handle_create(handle, make_playable_location(path.c_str(), subsong));

            if (handle.is_valid()) {
                result = performScan(handle, m_abort);
                if (!result && !m_cancelRequested.load()) {
                    error = "Scan failed";
                }
            } else {
                error = "Could not create track handle";
            }
        } catch (const exception_aborted&) {
            // Cancelled - not an error
        } catch (const std::exception& e) {
            pfc::string_formatter msg;
            msg << "Scan exception: " << e.what();
            console::error(msg.c_str());
            error = "Scan exception";
        } catch (...) {
            error = "Unknown scan error";
        }

        m_scanning.store(false);

        // Callback on main thread
        if (callback && !m_cancelRequested.load()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(result, error);
            });
        }
    });
}

std::optional<WaveformData> WaveformScanner::scanSync(const metadb_handle_ptr& track, abort_callback& abort) {
    return performScan(track, abort);
}

std::optional<WaveformData> WaveformScanner::performScan(const metadb_handle_ptr& track, abort_callback& abort) {
    if (!track.is_valid()) {
        return std::nullopt;
    }

    try {
        // Get track info
        file_info_impl info;
        if (!track->get_info_async(info)) {
            return std::nullopt;
        }

        double duration = info.get_length();
        if (duration <= 0) {
            return std::nullopt;
        }

        uint32_t channels = static_cast<uint32_t>(info.info_get_int("channels"));
        uint32_t sampleRate = static_cast<uint32_t>(info.info_get_int("samplerate"));

        if (channels == 0) channels = 2;
        if (sampleRate == 0) sampleRate = 44100;

        // Cap channels at 2
        channels = std::min(channels, 2u);

        // Open decoder
        input_helper decoder;
        decoder.open(nullptr, track, input_flag_simpledecode, abort);

        // Calculate samples per bucket
        uint64_t totalSamples = static_cast<uint64_t>(duration * sampleRate);
        size_t samplesPerBucket = static_cast<size_t>(totalSamples / WaveformData::BUCKET_COUNT);
        if (samplesPerBucket == 0) samplesPerBucket = 1;

        // Initialize waveform data
        WaveformData waveform;
        waveform.initialize(channels, sampleRate, duration);

        // Accumulators for current bucket
        std::vector<float> bucketMin(channels, 0.0f);
        std::vector<float> bucketMax(channels, 0.0f);
        std::vector<float> bucketSumSq(channels, 0.0f);
        size_t bucketSampleCount = 0;
        size_t currentBucket = 0;

        // Decode and process
        audio_chunk_impl_temporary chunk;

        while (decoder.run(chunk, abort)) {
            abort.check();

            const audio_sample* samples = chunk.get_data();
            size_t sampleCount = chunk.get_sample_count();
            uint32_t chunkChannels = chunk.get_channel_count();

            // Process interleaved samples
            for (size_t i = 0; i < sampleCount && currentBucket < WaveformData::BUCKET_COUNT; i++) {
                for (uint32_t ch = 0; ch < channels && ch < chunkChannels; ch++) {
                    float sample = samples[i * chunkChannels + ch];

                    if (bucketSampleCount == 0) {
                        bucketMin[ch] = sample;
                        bucketMax[ch] = sample;
                        bucketSumSq[ch] = sample * sample;
                    } else {
                        bucketMin[ch] = std::min(bucketMin[ch], sample);
                        bucketMax[ch] = std::max(bucketMax[ch], sample);
                        bucketSumSq[ch] += sample * sample;
                    }
                }
                bucketSampleCount++;

                // Complete bucket
                if (bucketSampleCount >= samplesPerBucket) {
                    for (uint32_t ch = 0; ch < channels; ch++) {
                        waveform.min[ch][currentBucket] = bucketMin[ch];
                        waveform.max[ch][currentBucket] = bucketMax[ch];
                        waveform.rms[ch][currentBucket] = std::sqrt(bucketSumSq[ch] / bucketSampleCount);

                        // Reset accumulators
                        bucketMin[ch] = 0.0f;
                        bucketMax[ch] = 0.0f;
                        bucketSumSq[ch] = 0.0f;
                    }
                    bucketSampleCount = 0;
                    currentBucket++;
                }
            }
        }

        // Handle remaining samples in last bucket
        if (bucketSampleCount > 0 && currentBucket < WaveformData::BUCKET_COUNT) {
            for (uint32_t ch = 0; ch < channels; ch++) {
                waveform.min[ch][currentBucket] = bucketMin[ch];
                waveform.max[ch][currentBucket] = bucketMax[ch];
                waveform.rms[ch][currentBucket] = std::sqrt(bucketSumSq[ch] / bucketSampleCount);
            }
            currentBucket++;
        }

        // Fill remaining buckets with zeros (for very short tracks)
        while (currentBucket < WaveformData::BUCKET_COUNT) {
            for (uint32_t ch = 0; ch < channels; ch++) {
                waveform.min[ch][currentBucket] = 0.0f;
                waveform.max[ch][currentBucket] = 0.0f;
                waveform.rms[ch][currentBucket] = 0.0f;
            }
            currentBucket++;
        }

        return waveform;

    } catch (const exception_aborted&) {
        throw; // Rethrow abort
    } catch (const std::exception& e) {
        pfc::string_formatter msg;
        msg << "[WaveSeek] Scan error: " << e.what();
        console::error(msg.c_str());
        return std::nullopt;
    }
}
