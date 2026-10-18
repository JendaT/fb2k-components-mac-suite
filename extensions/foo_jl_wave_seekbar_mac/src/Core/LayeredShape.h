//
//  LayeredShape.h
//  foo_wave_seekbar_mac
//
//  Style "Layered": mirrored halves (L up, R down) on one dBFS axis. The peak
//  envelope surrounds a K-weighted short-term loudness body; the gap between
//  them is the crest factor. Heights are fractions of a half, 0..1.
//  Header-only, tested standalone.
//

#pragma once

#include "ColumnAggregator.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace layered {

constexpr float kFloorDb = -36.0f;
constexpr float kGridDb[] = { -12.0f, -24.0f };

// dBFS -> fraction of the half height: floor -> 0, 0 dBFS -> 1
inline float fraction(float db, float floorDb = kFloorDb) {
    if (!(db > floorDb)) return 0.0f;           // also -inf and NaN
    return std::min(1.0f, (db - floorDb) / -floorDb);
}

struct Shape {
    // [0] = top half (left channel), [1] = bottom half (right channel)
    std::vector<float> peak[2];
    std::vector<float> body[2];
};

// Mono tracks show the one channel in both halves.
inline Shape shapeFor(const analysis::Columns& cols, float floorDb = kFloorDb) {
    Shape s;
    for (int half = 0; half < 2; ++half) {
        const int ch = cols.channels == 2 ? half : 0;
        s.peak[half].resize(cols.count);
        s.body[half].resize(cols.count);
        for (size_t c = 0; c < cols.count; ++c) {
            const float peak = std::max(-cols.min[ch][c], cols.max[ch][c]);
            const float peakDb = peak > 0.0f ? 20.0f * std::log10(peak) : -INFINITY;
            // K-weighting lifts highs by up to 4 dB; the body stays inside the peaks
            const float bodyDb = std::min(cols.level[ch][c], peakDb);
            s.peak[half][c] = fraction(peakDb, floorDb);
            s.body[half][c] = fraction(bodyDb, floorDb);
        }
    }
    return s;
}

} // namespace layered
