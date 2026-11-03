//
//  TrackDecode.mm
//  foo_jl_bpm_mac
//

#include "TrackDecode.h"

#include "BeatThisModel.h"
#include "MonoResampler.h"
#include "../Core/BpmValue.h"
#include "../Core/LogMelSpectrogram.h"
#include "../Core/NetworkBeats.h"
#include "../../../../shared/jl_tidal_api.h"

#include <helpers/input_helpers.h>

#include <algorithm>
#include <chrono>
#include <memory>

namespace bpm {

namespace {

// Guard against inputs that never end; a single BPM for hours of audio would
// be meaningless anyway.
constexpr double kMaxDecodeSeconds = 3.0 * 3600.0;

// The decoded audio on its way to the network: mono (channels averaged, as
// upstream does), 22.05 kHz as soxr resamples it, log-mel frames, chunks run
// as soon as they are complete
class NetworkFeed {
public:
    explicit NetworkFeed(double rate) : resampler_(rate), chunker_(kMelBands, runBeatThis) {}

    template <typename Sample>
    void add(const Sample *samples, size_t frames, unsigned channels) {
        if (failed_) return;
        const auto started = std::chrono::steady_clock::now();
        mono_.resize(frames);
        for (size_t i = 0; i < frames; i++) {
            double sum = 0.0;
            for (unsigned c = 0; c < channels; c++) sum += samples[i * channels + c];
            mono_[i] = static_cast<float>(sum / channels);
        }
        audio_.clear();
        resampler_.process(mono_.data(), frames, audio_);
        feed(false);
        seconds_ += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    }

    // The network's beats, or false when it failed somewhere
    bool finish(RawBeats &out, double &seconds) {
        const auto started = std::chrono::steady_clock::now();
        if (!failed_) {
            audio_.clear();
            resampler_.finish(audio_);
            feed(true);
        }
        failed_ = failed_ || !chunker_.finish();
        if (!failed_) out = networkBeats(chunker_.beatLogits(), chunker_.downbeatLogits());
        seconds_ += std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        seconds = seconds_;
        return !failed_;
    }

private:
    void feed(bool end) {
        if (!resampler_.ok()) {
            failed_ = true;
            return;
        }
        mel_.add(audio_.data(), audio_.size());
        if (end) mel_.finish();
        const std::vector<float> frames = mel_.take();
        if (!frames.empty() && !chunker_.add(frames.data(), static_cast<long>(frames.size() / kMelBands))) failed_ = true;
    }

    MonoResampler resampler_;
    LogMelSpectrogram mel_;
    NetworkChunker chunker_;
    std::vector<float> mono_, audio_;
    bool failed_ = false;
    double seconds_ = 0.0;
};

} // namespace

DecodedTrack decodeTrack(const metadb_handle_ptr &handle, abort_callback &abort, std::atomic<double> *progress) {
    DecodedTrack out;
    try {
        const double length = handle->get_length();  // <= 0 when unknown
        input_helper decoder;
        decoder.open(nullptr, handle, input_flag_simpledecode, abort);

        audio_chunk_impl_temporary chunk;
        std::unique_ptr<OnsetEnvelope> envelope;
        std::unique_ptr<NetworkFeed> network;
        unsigned rate = 0;
        while (decoder.run(chunk, abort)) {
            if (!envelope) {
                rate = chunk.get_sample_rate();
                envelope = std::make_unique<OnsetEnvelope>(rate);
                if (beatThisAvailable()) network = std::make_unique<NetworkFeed>(rate);
            } else if (chunk.get_sample_rate() != rate) {
                out.problem = "Sample rate changes within the track";
                return out;
            }
            envelope->addInterleaved(chunk.get_data(), chunk.get_sample_count(), chunk.get_channel_count());
            if (network) network->add(chunk.get_data(), chunk.get_sample_count(), chunk.get_channel_count());
            if (progress && length > 0.0) *progress = std::min(1.0, envelope->secondsAdded() / length);
            if (envelope->secondsAdded() > kMaxDecodeSeconds) break;
        }
        if (!envelope) {
            out.problem = "No audio decoded";
            return out;
        }
        if (network) out.networkRan = network->finish(out.network, out.networkSeconds);
        out.envelope = envelope->values();
        out.bands = envelope->bands();
        out.framesPerSecond = envelope->framesPerSecond();
        out.firstFrameSeconds = envelope->firstFrameSeconds();
        out.seconds = envelope->secondsAdded();
    } catch (exception_aborted const &) {
        throw;
    } catch (std::exception const &e) {
        out.problem = std::string("Could not decode: ") + e.what();
    }
    return out;
}

BeatGrid analyseDecodedTrack(const DecodedTrack &track, const BeatGridHints &hints) {
    if (track.networkRan) {
        return analyseNetworkBeatGrid(track.network, track.envelope, track.bands, track.framesPerSecond,
                                      track.firstFrameSeconds, track.seconds);
    }
    return analyseBeatGrid(track.envelope, track.bands, track.framesPerSecond, track.firstFrameSeconds, track.seconds,
                           hints);
}

BeatGridHints hintsFor(const metadb_handle_ptr &handle) {
    BeatGridHints hints;
    metadb_info_container::ptr info;
    if (handle->get_info_ref(info)) {
        if (const char *value = info->info().meta_get("BPM", 0)) {
            if (const auto bpm = parseBpm(value)) hints.tagBpm = *bpm;
        }
    }
    jl_tidal_lookup::ptr tidal;
    jl_tidal_track_facts facts;
    if (fb2k::std_api_try_get(tidal) && tidal->get_cached(handle, facts) && facts.status == jl_tidal_status_found &&
        (facts.match == jl_tidal_match_track_id || facts.match == jl_tidal_match_isrc) && facts.bpm > 0.0f) {
        hints.tidalBpm = facts.bpm;
    }
    return hints;
}

} // namespace bpm
