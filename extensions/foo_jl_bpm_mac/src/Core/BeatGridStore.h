//
//  BeatGridStore.h
//  foo_jl_bpm_mac
//
//  A track's beat grid as stored per track (the metadb index blob) and
//  served through jl_beatgrid: the API's summary, regions and bars, or the
//  fact that the track was analysed and has no grid. Plain C++, unit tested.
//
//  Blob: "JLBG", format version, then little-endian fields. A blob of
//  another version or a damaged one reads as nothing stored, so the track is
//  simply analysed again.
//

#pragma once

#include "BeatGridAnalyzer.h"
#include "../../../../shared/jl_beatgrid_types.h"

#include <cstdint>
#include <optional>
#include <vector>

namespace bpm {

// 2: bars start on the bar phase (stage 6). 3: bar statistics from the
// onsets at the grid beats, phases from clustered section changes, off-beat
// bars flagged. 4: grids from the Beat This! network where its model loads;
// master grids refitted over the whole track. Grids of an older version are
// analysed again.
constexpr uint32_t kStoredGridVersion = 4;

struct StoredGrid {
    bool available = false;         // false: analysed, but no grid (no pulse, too short)
    jl_beatgrid_summary summary{};
    std::vector<jl_beat_region> regions;
    std::vector<jl_bar_stat> bars;
};

// The analysis result in API form; an invalid grid is stored as unavailable
StoredGrid toStored(const BeatGrid &grid);

std::vector<uint8_t> encodeStoredGrid(const StoredGrid &grid);
std::optional<StoredGrid> decodeStoredGrid(const uint8_t *data, size_t size);

// Share of bars that are Locked on their own, for the console line
double lockedShare(const std::vector<jl_bar_stat> &bars);

} // namespace bpm
