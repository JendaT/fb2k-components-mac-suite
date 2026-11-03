//
//  TrackDecode.mm
//  foo_jl_bpm_mac
//

#include "TrackDecode.h"

#include "../Core/BpmValue.h"
#include "../../../../shared/jl_tidal_api.h"

#include <helpers/input_helpers.h>

#include <algorithm>
#include <memory>

namespace bpm {

namespace {

// Guard against inputs that never end; a single BPM for hours of audio would
// be meaningless anyway.
constexpr double kMaxDecodeSeconds = 3.0 * 3600.0;

} // namespace

DecodedTrack decodeTrack(const metadb_handle_ptr &handle, abort_callback &abort, std::atomic<double> *progress) {
    DecodedTrack out;
    try {
        const double length = handle->get_length();  // <= 0 when unknown
        input_helper decoder;
        decoder.open(nullptr, handle, input_flag_simpledecode, abort);

        audio_chunk_impl_temporary chunk;
        std::unique_ptr<OnsetEnvelope> envelope;
        unsigned rate = 0;
        while (decoder.run(chunk, abort)) {
            if (!envelope) {
                rate = chunk.get_sample_rate();
                envelope = std::make_unique<OnsetEnvelope>(rate);
            } else if (chunk.get_sample_rate() != rate) {
                out.problem = "Sample rate changes within the track";
                return out;
            }
            envelope->addInterleaved(chunk.get_data(), chunk.get_sample_count(), chunk.get_channel_count());
            if (progress && length > 0.0) *progress = std::min(1.0, envelope->secondsAdded() / length);
            if (envelope->secondsAdded() > kMaxDecodeSeconds) break;
        }
        if (!envelope) {
            out.problem = "No audio decoded";
            return out;
        }
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
