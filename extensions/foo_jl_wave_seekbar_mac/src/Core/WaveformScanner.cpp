//
//  WaveformScanner.cpp
//  foo_wave_seekbar_mac
//
//  Async decode of a track through the TrackAnalyzer
//

#include "WaveformScanner.h"
#include "TrackAnalyzer.h"
#include <chrono>
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
    std::lock_guard<std::mutex> lock(m_abortMutex);
    if (m_currentAbort) {
        m_currentAbort->abort();
        m_currentAbort.reset();
    }
    // Bump the generation so the aborted scan stays silent instead of reporting
    // a failure for a request nobody is waiting on any more.
    ++m_generation;
    m_scanning.store(false);
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

    // Cancel any existing scan, then hand this one its own abort object
    cancel();

    auto abort = std::make_shared<abort_callback_impl>();
    uint64_t gen;
    {
        std::lock_guard<std::mutex> lock(m_abortMutex);
        m_currentAbort = abort;
        gen = ++m_generation;
    }
    m_scanning.store(true);

    // Capture track path for the block
    pfc::string8 path = track->get_path();
    t_uint32 subsong = track->get_subsong_index();

    // Dispatch to background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::optional<WaveformData> result;
        const char* error = nullptr;
        bool aborted = false;

        // Skip the decode if a newer scan already superseded this one, but still
        // fall through to the bookkeeping below so m_scanning cannot stick on.
        if (m_generation.load() == gen) {
            try {
                // Re-obtain handle on background thread
                metadb_handle_ptr handle;
                metadb::get()->handle_create(handle, make_playable_location(path.c_str(), subsong));

                if (handle.is_valid()) {
                    result = performScan(handle, *abort);
                    if (!result) {
                        error = "Scan failed";
                    }
                } else {
                    error = "Could not create track handle";
                }
            } catch (const exception_aborted&) {
                // Cancelled - not an error
                aborted = true;
            } catch (const std::exception& e) {
                pfc::string_formatter msg;
                msg << "Scan exception: " << e.what();
                console::error(msg.c_str());
                error = "Scan exception";
            } catch (...) {
                error = "Unknown scan error";
            }
        }

        // Only the scan that still owns m_currentAbort clears the running state;
        // a superseded scan must not report the newer one as finished.
        {
            std::lock_guard<std::mutex> lock(m_abortMutex);
            if (m_currentAbort == abort) {
                m_currentAbort.reset();
                m_scanning.store(false);
            }
        }

        if (aborted) return;

        // Callback on main thread only if this generation is still current
        if (callback && m_generation.load() == gen) {
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

// One segment through its own decoder: the pre-roll that settles the
// filters, the segment, then the few frames that finish clip runs crossing
// its end
WaveformData analyseSegment(input_helper& decoder, const analysis::Segment& segment, uint32_t channels,
                            uint32_t sampleRate, uint64_t expectedFrames, abort_callback& abort) {
    analysis::TrackAnalyzer analyzer(sampleRate, channels, expectedFrames);
    analyzer.setRange(segment.start, segment.end);

    const uint64_t preroll = static_cast<uint64_t>(analysis::kSegmentPrerollSeconds * sampleRate);
    const uint64_t from = segment.start > preroll ? segment.start - preroll : 0;
    const uint64_t to = segment.end == UINT64_MAX ? UINT64_MAX : segment.end + analysis::kClipRunLength - 1;
    if (from > 0) {
        decoder.seek(static_cast<double>(from) / sampleRate, abort);
    }
    analyzer.setPosition(from);

    audio_chunk_impl_temporary chunk;
    while (analyzer.position() < to && decoder.run(chunk, abort)) {
        abort.check();
        // Boundaries are frame counts at the nominal rate; a rate change would
        // shift them, so let the caller fall back to one pass
        if (chunk.get_sample_rate() != sampleRate) {
            throw exception_unexpected_audio_format_change();
        }
        const size_t frames = static_cast<size_t>(
            std::min<uint64_t>(chunk.get_sample_count(), to - analyzer.position()));
        analyzer.process(chunk.get_data(), frames, chunk.get_channel_count());
    }
    return analyzer.finish();
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

        // Open decoder. Seeking stays allowed (no input_flag_no_seeking) since
        // segments seek; some inputs skip building seek tables otherwise
        input_helper decoder;
        decoder.open(nullptr, track, input_flag_no_looping, abort);
        const auto started = std::chrono::steady_clock::now();

        // One decoder on one core is slow for long tracks. Split them into
        // segments analysed in parallel, unless seeking is unavailable or
        // slow, or the file is remote (parallel reads multiply traffic)
        const uint64_t expectedFrames = static_cast<uint64_t>(duration * sampleRate);
        std::vector<analysis::Segment> segments = { { 0, UINT64_MAX } };
        if (decoder.can_seek() && !decoder.extended_param(input_params::seeking_expensive) &&
            !filesystem::g_is_remote_or_unrecognized(track->get_path())) {
            segments = analysis::planSegments(expectedFrames, sampleRate);
        }

        std::optional<WaveformData> result;
        if (segments.size() > 1) {
            // Workers take segments from a shared counter, each reusing its own decoder
            std::vector<WaveformData> parts(segments.size());
            std::atomic<size_t> nextSegment{0};
            std::atomic<bool> failed{false};
            const uint32_t analysedChannels = std::min(channels, 2u);
            const size_t workers = std::min<size_t>(segments.size(), pfc::getOptimalWorkerThreadCount());

            fb2k::cpuThreadPool::runMultiHelper([&] {
                try {
                    input_helper segmentDecoder;
                    segmentDecoder.open(nullptr, track, input_flag_no_looping, abort);
                    for (size_t i; !failed && (i = nextSegment++) < segments.size();) {
                        parts[i] = analyseSegment(segmentDecoder, segments[i], analysedChannels, sampleRate,
                                                  expectedFrames, abort);
                    }
                } catch (...) {
                    failed = true;
                }
            }, workers);

            abort.check();
            if (!failed) {
                WaveformData joined = analysis::TrackAnalyzer::merge(std::move(parts));
                if (joined.isValid()) result = std::move(joined);
            }
        }

        // One pass for short or unsegmentable tracks, and when a segment
        // failed to seek or decode. The first chunk tells the real format.
        if (!result) {
            segments.assign(1, { 0, UINT64_MAX });
            std::optional<analysis::TrackAnalyzer> analyzer;
            audio_chunk_impl_temporary chunk;
            while (decoder.run(chunk, abort)) {
                abort.check();
                if (!analyzer) {
                    if (chunk.get_sample_rate() > 0) sampleRate = chunk.get_sample_rate();
                    if (chunk.get_channel_count() > 0) channels = chunk.get_channel_count();
                    analyzer.emplace(sampleRate, std::min(channels, 2u),
                                     static_cast<uint64_t>(duration * sampleRate));
                }
                analyzer->process(chunk.get_data(), chunk.get_sample_count(), chunk.get_channel_count());
            }
            if (!analyzer) return std::nullopt;
            result = analyzer->finish();
        }
        if (!result->isValid()) return std::nullopt;
        WaveformData waveform = std::move(*result);

        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        const LoudnessSummary& sum = waveform.summary;
        FB2K_console_formatter() << "[WaveSeek] Analysed " << track->get_path() << " in "
            << pfc::format_float(seconds, 0, 2) << " s (" << segments.size()
            << (segments.size() == 1 ? " pass" : " segments") << "): I " << pfc::format_float(sum.integrated, 0, 1)
            << " LUFS, LRA " << pfc::format_float(sum.range, 0, 1)
            << " LU, TP " << pfc::format_float(sum.truePeak, 0, 1)
            << " dBTP, PLR " << pfc::format_float(sum.plr(), 0, 1)
            << ", " << sum.clipRuns << " clip runs";
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
