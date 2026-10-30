//
//  ColumnAggregator.h
//  foo_wave_seekbar_mac
//
//  Per-column values for one view width, aggregated from a track's cached
//  block arrays: drawing envelopes and the hover readout. Pure C++, tested
//  standalone.
//

#pragma once

#include "WaveformData.h"
#include <cstddef>
#include <vector>

namespace waveseek::analysis {

struct Columns {
    size_t count = 0;
    uint32_t channels = 0;

    // Per channel, linear. Wide views interpolate between blocks; narrow
    // views merge them (min of minima, max of maxima, power mean of RMS).
    std::vector<float> min[2], max[2], rms[2];

    // Per channel K-weighted level in dB (10 log10 of mean square), the
    // loudest within the column: short-term (3 s, centred) and momentary
    // (400 ms, centred). -inf = silence.
    std::vector<float> level[2];
    std::vector<float> momentary[2];

    // Lo / Mid / Hi share of band power over 10 s around the column's centre,
    // all channels: the spectral balance of the passage. NaN where silent.
    std::vector<float> tintShare[3];

    // Readout, all channels together. NaN where silent / undefined.
    std::vector<float> lufs;            // short-term loudness, LUFS
    std::vector<float> peakDb;          // largest sample, dBFS
    std::vector<float> crestDb;         // peak minus RMS, dB
    std::vector<float> correlation;     // -1..+1 (+1 for mono)
    std::vector<float> bandShare[3];    // Lo / Mid / Hi share of band power, 0..1
};

Columns aggregateColumns(const WaveformData& data, size_t columns);

// Both channels as one (channels = 1): the widest min / max, the power mean
// of RMS and levels. Readout and tint values are already for all channels
// and copy over. Mono input comes back unchanged.
Columns mixdown(const Columns& stereo);

} // namespace waveseek::analysis
