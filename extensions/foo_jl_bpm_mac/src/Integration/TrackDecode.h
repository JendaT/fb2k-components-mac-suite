//
//  TrackDecode.h
//  foo_jl_bpm_mac
//
//  One decode of a track into its onset envelope and band energies, and the
//  Beat This! network's beats when its model is available: what both the
//  tempo estimate and the beat grid are computed from, so "Analyze BPM" and
//  the beat grid service share a single pass per track.
//

#pragma once

#include "../fb2k_sdk.h"
#include "../Core/BeatGridAnalyzer.h"

#include <atomic>
#include <string>
#include <vector>

namespace bpm {

struct DecodedTrack {
    std::vector<float> envelope;
    BandEnergies bands;
    double framesPerSecond = 0.0;
    double firstFrameSeconds = 0.0;
    double seconds = 0.0;           // decoded audio
    std::string problem;            // why nothing usable was decoded; empty on success
    bool networkRan = false;        // the network heard the whole track (its beats may still be none)
    RawBeats network;
    double networkSeconds = 0.0;    // spent in it, resampling and front end included
};

// Decodes `handle` from start to end. `progress` (optional) follows the
// decoded share of the track. Throws exception_aborted; other decode errors
// end up in `problem`.
DecodedTrack decodeTrack(const metadb_handle_ptr &handle, abort_callback &abort,
                         std::atomic<double> *progress = nullptr);

// Tempo references for the beat grid: the BPM tag, and TIDAL's tempo when
// its cache has the exact track (track ID or ISRC match)
BeatGridHints hintsFor(const metadb_handle_ptr &handle);

// The track's grid from one decode: from the network's beats when it ran
// (no grid when it heard none), else from the classic tracker
BeatGrid analyseDecodedTrack(const DecodedTrack &track, const BeatGridHints &hints);

} // namespace bpm
