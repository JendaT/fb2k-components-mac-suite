//
//  WaveformScanner.cpp
//  foo_wave_seekbar_mac
//
//  Async audio scanning with peak extraction
//

#include "WaveformScanner.h"
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <vector>

// Construct-on-first-use singleton to avoid static initialization order issues
WaveformScanner& getWaveformScanner() {
    static WaveformScanner g_scanner;
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

    // Reset state with new generation
    uint64_t gen = ++m_generation;
    m_cancelRequested.store(false);
    m_abort.reset();
    m_scanning.store(true);

    // Capture track path for the block
    pfc::string8 path = track->get_path();
    t_uint32 subsong = track->get_subsong_index();

    // Dispatch to background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if this scan is still current
        if (m_generation.load() != gen) return;

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

        // Callback on main thread only if this generation is still current
        if (callback && m_generation.load() == gen && !m_cancelRequested.load()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(result, error);
            });
        }
    });
}

std::optional<WaveformData> WaveformScanner::scanSync(const metadb_handle_ptr& track, abort_callback& abort) {
    return performScan(track, abort);
}

namespace {

// Long tracks are split into segments of at least this length, decoded in parallel
constexpr double kMinSegmentDuration = 30.0;
// More segments than workers so a worker stuck on an efficiency core delays
// the result less; 64 measured ~30% faster than one segment per core
constexpr size_t kMaxSegments = 64;

struct Bucket {
    audio_sample min[2] = {std::numeric_limits<audio_sample>::infinity(), std::numeric_limits<audio_sample>::infinity()};
    audio_sample max[2] = {-std::numeric_limits<audio_sample>::infinity(), -std::numeric_limits<audio_sample>::infinity()};
    double sumSq[2] = {0, 0};
    uint64_t count = 0;
};

// Samples are assigned to buckets by absolute position, so segments decoded
// independently give the same result as one sequential pass
class BucketLayout {
public:
    explicit BucketLayout(uint64_t totalSamples) : m_total(std::max<uint64_t>(totalSamples, 1)) {}

    uint64_t start(size_t bucket) const {
        return static_cast<uint64_t>(bucket) * m_total / WaveformData::BUCKET_COUNT;
    }

    // The last bucket takes any samples past the reported length
    uint64_t end(size_t bucket) const {
        return bucket + 1 >= WaveformData::BUCKET_COUNT
            ? std::numeric_limits<uint64_t>::max()
            : start(bucket + 1);
    }

private:
    uint64_t m_total;
};

// Decodes buckets [firstBucket, lastBucket) into `buckets`
void scanSegment(input_helper& decoder, const BucketLayout& layout,
                 size_t firstBucket, size_t lastBucket,
                 uint32_t channels, uint32_t sampleRate,
                 std::vector<Bucket>& buckets, abort_callback& abort) {
    uint64_t pos = layout.start(firstBucket);
    const uint64_t end = layout.end(lastBucket - 1);
    const bool wholeTrack = firstBucket == 0 && lastBucket == WaveformData::BUCKET_COUNT;

    if (pos > 0) {
        decoder.seek(static_cast<double>(pos) / sampleRate, abort);
    }

    size_t bucket = firstBucket;
    uint64_t bucketEnd = layout.end(bucket);

    audio_chunk_impl_temporary chunk;
    while (pos < end && decoder.run(chunk, abort)) {
        abort.check();

        // Segment boundaries are sample counts at the nominal rate; a rate
        // change would shift them, so let the caller fall back to one pass
        if (!wholeTrack && chunk.get_sample_rate() != sampleRate) {
            throw exception_unexpected_audio_format_change();
        }

        const audio_sample* samples = chunk.get_data();
        const size_t sampleCount = chunk.get_sample_count();
        const uint32_t chunkChannels = chunk.get_channel_count();
        if (chunkChannels == 0) continue;

        size_t i = 0;
        while (i < sampleCount && pos < end) {
            // Skips empty buckets too (tracks shorter than BUCKET_COUNT samples)
            while (pos >= bucketEnd) {
                bucketEnd = layout.end(++bucket);
            }

            const vDSP_Length n = static_cast<vDSP_Length>(
                std::min<uint64_t>({sampleCount - i, bucketEnd - pos, end - pos}));
            Bucket& b = buckets[bucket];

            for (uint32_t ch = 0; ch < channels; ch++) {
                const audio_sample* src = samples + i * chunkChannels + std::min(ch, chunkChannels - 1);
                audio_sample mn, mx, sq;
#if audio_sample_size == 64
                vDSP_minvD(src, chunkChannels, &mn, n);
                vDSP_maxvD(src, chunkChannels, &mx, n);
                vDSP_svesqD(src, chunkChannels, &sq, n);
#else
                vDSP_minv(src, chunkChannels, &mn, n);
                vDSP_maxv(src, chunkChannels, &mx, n);
                vDSP_svesq(src, chunkChannels, &sq, n);
#endif
                b.min[ch] = std::min(b.min[ch], mn);
                b.max[ch] = std::max(b.max[ch], mx);
                b.sumSq[ch] += sq;
            }
            b.count += n;
            pos += n;
            i += n;
        }
    }
}

}  // namespace

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

        // Open decoder. Seeking stays allowed (no input_flag_no_seeking) since
        // segments seek; some inputs skip building seek tables otherwise
        input_helper decoder;
        decoder.open(nullptr, track, input_flag_no_looping, abort);

        // One decoder on one core took ~4s for a 2h mix. Split long tracks
        // into segments decoded in parallel, unless seeking is unavailable or
        // slow, or the file is remote (parallel reads multiply traffic)
        size_t segments = 1;
        if (decoder.can_seek() && !decoder.extended_param(input_params::seeking_expensive) &&
            !filesystem::g_is_remote_or_unrecognized(track->get_path())) {
            segments = std::clamp<size_t>(static_cast<size_t>(duration / kMinSegmentDuration), 1, kMaxSegments);
        }

        const BucketLayout layout(static_cast<uint64_t>(duration * sampleRate));
        std::vector<Bucket> buckets(WaveformData::BUCKET_COUNT);

        bool parallelDone = false;
        if (segments > 1) {
            // Workers take segments from a shared counter, each reusing its own decoder
            std::atomic<size_t> nextSegment{0};
            std::atomic<bool> failed{false};
            const size_t workers = std::min<size_t>(segments, pfc::getOptimalWorkerThreadCount());

            fb2k::cpuThreadPool::runMultiHelper([&] {
                try {
                    input_helper segmentDecoder;
                    segmentDecoder.open(nullptr, track, input_flag_no_looping, abort);
                    for (size_t seg; !failed && (seg = nextSegment++) < segments;) {
                        scanSegment(segmentDecoder, layout,
                                    seg * WaveformData::BUCKET_COUNT / segments,
                                    (seg + 1) * WaveformData::BUCKET_COUNT / segments,
                                    channels, sampleRate, buckets, abort);
                    }
                } catch (...) {
                    failed = true;
                }
            }, workers);

            abort.check();
            parallelDone = !failed;
        }

        // Single pass for short or unsegmentable tracks, and when a segment
        // failed to seek or decode
        if (!parallelDone) {
            if (segments > 1) {
                buckets.assign(WaveformData::BUCKET_COUNT, Bucket{});
            }
            scanSegment(decoder, layout, 0, WaveformData::BUCKET_COUNT,
                        channels, sampleRate, buckets, abort);
        }

        // Buckets with no samples (very short tracks) stay zero
        WaveformData waveform;
        waveform.initialize(channels, sampleRate, duration);

        for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
            const Bucket& b = buckets[i];
            if (b.count == 0) continue;
            for (uint32_t ch = 0; ch < channels; ch++) {
                waveform.min[ch][i] = static_cast<float>(b.min[ch]);
                waveform.max[ch][i] = static_cast<float>(b.max[ch]);
                waveform.rms[ch][i] = static_cast<float>(std::sqrt(b.sumSq[ch] / b.count));
            }
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
