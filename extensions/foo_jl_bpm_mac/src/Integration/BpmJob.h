//
//  BpmJob.h
//  foo_jl_bpm_mac
//
//  One "Analyze BPM" run: the selected tracks and what was found for each.
//  Filled by the analysis (BpmAnalysis.mm), then handed to the review
//  window, which is the only reader once the analysis has finished.
//

#pragma once

#include "../fb2k_sdk.h"

#include <optional>
#include <string>
#include <vector>

namespace bpm {

enum class ResultSource {
    None,
    Tidal,     // TIDAL catalogue, matched by track ID or ISRC
    Analysis,  // decoded and analysed on this Mac
};

struct TrackRow {
    metadb_handle_ptr handle;
    std::string currentTag;            // existing BPM tag text, may be empty
    std::optional<double> currentBpm;  // currentTag parsed
    bool hasIsrc = false;
    bool isTidalStream = false;        // tidal:// entry: no file to decode or tag
    bool isLocalFile = false;          // decodable and taggable

    ResultSource source = ResultSource::None;
    double bpm = 0.0;                  // unrounded
    double strength = 0.0;             // local analysis only, see TempoResult
    std::string problem;               // why there is no result
};

struct AnalysisJob {
    std::vector<TrackRow> rows;
};

} // namespace bpm
