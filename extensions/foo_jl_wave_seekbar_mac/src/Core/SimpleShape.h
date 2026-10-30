//
//  SimpleShape.h
//  foo_wave_seekbar_mac
//
//  Styles "Simple" (Two-tone, Glow, Heat): two separate lanes, L on top and
//  R below, each around its own centre line, on a linear amplitude scale.
//  The peak layer follows the sample minimum and maximum; the RMS core is
//  RMS x sqrt(2) (a sine's core then meets its peaks). Heights are signed
//  fractions of a lane's half height, -1..1. Header-only, tested standalone.
//

#pragma once

#include "ColumnAggregator.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace waveseek::simple {

struct Lane {
    std::vector<float> top, bottom;             // peak layer: max >= 0 >= min
    std::vector<float> coreTop, coreBottom;     // RMS core, inside the peaks
};

struct Shape {
    int lanes = 2;
    Lane lane[2];                               // [0] = left (top lane), [1] = right
};

// `lanes` 2: L and R (a mono track shows its one channel in both); 1: one
// lane from the first channel, for mixed-down columns.
inline Shape shapeFor(const analysis::Columns& cols, int lanes = 2) {
    const float kCoreScale = 1.41421356f;
    Shape s;
    s.lanes = lanes == 1 ? 1 : 2;
    for (int l = 0; l < s.lanes; ++l) {
        const int ch = cols.channels == 2 ? l : 0;
        Lane& lane = s.lane[l];
        lane.top.resize(cols.count);
        lane.bottom.resize(cols.count);
        lane.coreTop.resize(cols.count);
        lane.coreBottom.resize(cols.count);
        for (size_t c = 0; c < cols.count; ++c) {
            const float top = std::clamp(cols.max[ch][c], 0.0f, 1.0f);
            const float bottom = std::clamp(cols.min[ch][c], -1.0f, 0.0f);
            const float core = cols.rms[ch][c] * kCoreScale;
            lane.top[c] = top;
            lane.bottom[c] = bottom;
            lane.coreTop[c] = std::min(core, top);
            lane.coreBottom[c] = std::max(-core, bottom);
        }
    }
    return s;
}

} // namespace waveseek::simple
