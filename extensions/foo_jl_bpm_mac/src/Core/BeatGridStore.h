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
// master grids refitted over the whole track. 5: the network's unsure 16ths
// no longer start a new grid; off-grid beats count only when it is very
// sure. 6: sections, one per grid where a new one is confirmed. Grids of an
// older version are analysed again.
constexpr uint32_t kStoredGridVersion = 6;

struct StoredGrid {
    bool available = false;         // false: analysed, but no grid (no pulse, too short)
    jl_beatgrid_summary summary{};
    std::vector<jl_beat_region> regions;
    std::vector<jl_bar_stat> bars;
    // Where a new grid is confirmed: one section per grid and their bars;
    // empty when the master grid holds throughout
    std::vector<jl_grid_section> sections;
    std::vector<jl_bar_stat> sectionBars;
};

// The analysis result in API form; an invalid grid is stored as unavailable
StoredGrid toStored(const BeatGrid &grid);

std::vector<uint8_t> encodeStoredGrid(const StoredGrid &grid);
std::optional<StoredGrid> decodeStoredGrid(const uint8_t *data, size_t size);

// The grid section by section as jl_beatgrid::get_sections serves it: the
// stored sections, or the master grid as the only one. False when the grid
// is unavailable.
bool sectionsOf(const StoredGrid &grid, std::vector<jl_grid_section> &sections, std::vector<jl_bar_stat> &bars);

// Share of bars that are Locked on their own, for the console line
double lockedShare(const std::vector<jl_bar_stat> &bars);

} // namespace bpm
