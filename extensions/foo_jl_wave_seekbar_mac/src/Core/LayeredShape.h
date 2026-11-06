//
//  LayeredShape.h
//  foo_wave_seekbar_mac
//
//  Style "Layered": each channel mirrored about its lane's centre on a dBFS
//  axis, L above R. The peak envelope surrounds a K-weighted momentary
//  (400 ms) loudness body; the gap between them is the crest factor. Heights
//  are fractions of half a lane, 0..1.
//  The body is tinted by the passage's spectral balance (tintPositions).
//  Header-only, tested standalone.
//

#pragma once

#include "ColumnAggregator.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace waveseek::layered {

constexpr float kFloorDb = -36.0f;
constexpr float kGridDb[] = { -12.0f, -24.0f };

// dBFS -> fraction of half a lane: floor -> 0, 0 dBFS -> 1
inline float fraction(float db, float floorDb = kFloorDb) {
    if (!(db > floorDb)) return 0.0f;           // also -inf and NaN
    return std::min(1.0f, (db - floorDb) / -floorDb);
}

struct Shape {
    int lanes = 0;
    // Per lane: [0] = left channel (top), [1] = right channel (bottom)
    std::vector<float> peak[2];
    std::vector<float> body[2];
};

// One lane per channel; mono columns (a mono track, or the mix) give one.
inline Shape shapeFor(const analysis::Columns& cols, float floorDb = kFloorDb) {
    Shape s;
    s.lanes = cols.channels == 2 ? 2 : 1;
    for (int ch = 0; ch < s.lanes; ++ch) {
        s.peak[ch].resize(cols.count);
        s.body[ch].resize(cols.count);
        for (size_t c = 0; c < cols.count; ++c) {
            const float peak = std::max(-cols.min[ch][c], cols.max[ch][c]);
            const float peakDb = peak > 0.0f ? 20.0f * std::log10(peak) : -INFINITY;
            // K-weighting lifts highs by up to 4 dB; the body stays inside the peaks
            const float bodyDb = std::min(cols.momentary[ch][c], peakDb);
            s.peak[ch][c] = fraction(peakDb, floorDb);
            s.body[ch][c] = fraction(bodyDb, floorDb);
        }
    }
    return s;
}

// Where each column sits between the track's most bass-heavy (0) and
// brightest (1) passages: the spectral centroid of its Lo / Mid / Hi shares
// (Lo = 0, Mid = 0.5, Hi = 1), stretched over the track's 5th to 95th
// percentile so every track shows its own range. 0.5 where silent, and
// everywhere when the track barely varies.
inline std::vector<float> tintPositions(const analysis::Columns& cols) {
    const float kMinRange = 0.01f;
    std::vector<float> centroid(cols.count, NAN), known;
    for (size_t c = 0; c < cols.count; ++c) {
        const float mid = cols.tintShare[1][c], hi = cols.tintShare[2][c];
        if (std::isnan(mid) || std::isnan(hi)) continue;
        centroid[c] = 0.5f * mid + hi;
        known.push_back(centroid[c]);
    }
    std::vector<float> out(cols.count, 0.5f);
    if (known.size() < 2) return out;
    std::sort(known.begin(), known.end());
    const float low = known[known.size() * 5 / 100];
    const float high = known[std::min(known.size() - 1, known.size() * 95 / 100)];
    if (high - low < kMinRange) return out;
    for (size_t c = 0; c < cols.count; ++c) {
        if (!std::isnan(centroid[c])) out[c] = std::clamp((centroid[c] - low) / (high - low), 0.0f, 1.0f);
    }
    return out;
}

} // namespace waveseek::layered
