//
//  BeatGridService.h
//  foo_jl_bpm_mac
//
//  The jl_beatgrid provider (shared/jl_beatgrid_api.h): beat grids stored
//  per track in a metadb index keyed on path and subsong, analysed one track
//  at a time on a background-priority thread, the playing track first.
//

#pragma once

#include "../fb2k_sdk.h"
#include "../Core/BeatGridAnalyzer.h"

namespace bpm {

// Stores a grid from an analysis that decoded the track anyway ("Analyze
// BPM"), logs it and tells the consumers. Any thread.
void storeAnalysedGrid(const metadb_handle_ptr &item, const BeatGrid &grid, double seconds);

} // namespace bpm
