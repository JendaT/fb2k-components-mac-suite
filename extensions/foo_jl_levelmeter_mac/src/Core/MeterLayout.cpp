//
//  MeterLayout.cpp
//  foo_jl_levelmeter_mac
//

#include "MeterLayout.h"
#include <algorithm>
#include <cmath>

namespace meter_layout {

namespace {

const double kGroupGap = 12.0;      // level group to loudness group
const double kPairGap = 3.0;        // between M and S
const double kMinBarsLength = 60.0;
const double kMinHorizontalBars = 80.0;
const double kStatsHeight = 2 * kStatsRow + 4.0;
const double kStereoHeight = 2 * kStereoRow + 4.0;

Result vertical(const Input &in) {
    Result r;
    r.vertical = true;
    const double W = in.width - 2 * kPad, H = in.height - 2 * kPad;
    if (W <= 0 || H <= 0) return r;

    bool readouts = in.readouts, stats = in.loudness, stereo = in.stereo, loudBars = in.loudness;
    const double clipH = kClipSize + 3.0;
    const double labelH = kLabelSize + 2.0;
    auto barsLength = [&] {
        return H - (readouts ? kReadoutHeight + 2.0 : 0.0) - clipH - labelH -
               (stats ? kStatsHeight : 0.0) - (stereo ? kStereoHeight : 0.0);
    };
    // Short panels give up the extras before the bars get too short.
    if (barsLength() < kMinBarsLength) stereo = false;
    if (barsLength() < kMinBarsLength) stats = false;
    if (barsLength() < kMinBarsLength) readouts = false;
    const double barsH = std::max(0.0, barsLength());

    // Bar widths: all four equal, capped so wide panels don't get slabs.
    double barW = 0.0;
    auto fit = [&] {
        if (loudBars) {
            const double fixed = 2 * kScaleWidth + kGroupGap + kPairGap;
            barW = std::min(kMaxBarWidth, (W - fixed) / 4.0);
        } else {
            barW = std::min(kMaxBarWidth, (W - kScaleWidth) / 2.0);
        }
    };
    fit();
    if (loudBars && barW < 6.0) { loudBars = false; fit(); }
    barW = std::floor(std::max(barW, 1.0));

    const double contentW = loudBars ? 4 * barW + 2 * kScaleWidth + kGroupGap + kPairGap
                                     : 2 * barW + kScaleWidth;
    const double x0 = std::round(kPad + (W - contentW) / 2.0);
    double y = kPad;

    const double readoutY = y;
    if (readouts) y += kReadoutHeight + 2.0;
    const double clipY = y;
    y += clipH;
    const double barsY = y;
    y += barsH;
    const double labelY = y + 2.0;
    y += labelH;

    double xs[BarCount];
    xs[BarL] = x0;
    xs[BarR] = x0 + barW + kScaleWidth;
    xs[BarM] = xs[BarR] + barW + kGroupGap;
    xs[BarS] = xs[BarM] + barW + kPairGap;
    const int bars = loudBars ? 4 : 2;
    for (int i = 0; i < bars; ++i) {
        r.bar[i] = { xs[i], barsY, barW, barsH };
        r.label[i] = { xs[i] - 4, labelY, barW + 8, kLabelSize };
        // Loudness numbers have only the narrow pair gap to spill into.
        if (readouts && (i <= BarR || barW >= 26.0)) {
            // Numbers may be wider than a thin bar: let them spill into the gaps.
            const double spill = i == BarM || i == BarS ? kPairGap / 2.0 + 2.0 : 6.0;
            r.readout[i] = { xs[i] - spill, readoutY, barW + 2 * spill, kReadoutHeight };
        }
    }
    for (int c = 0; c < 2; ++c) {
        const double cw = std::min(barW, 18.0);
        r.clip[c] = { xs[c] + (barW - cw) / 2.0, clipY, cw, kClipSize };
    }
    r.scale = { xs[BarL] + barW, barsY, kScaleWidth, barsH };
    if (loudBars) r.loudnessScale = { xs[BarS] + barW, barsY, kScaleWidth, barsH };

    const double fullX = kPad, fullW = W;
    if (stats) {
        r.stats = { fullX, y + 2.0, fullW, kStatsHeight - 2.0 };
        r.statsTwoColumns = fullW >= 150.0;
        y += kStatsHeight;
    }
    if (stereo) {
        r.correlation = { fullX, y + 2.0, fullW, kStereoRow };
        r.balance = { fullX, y + 2.0 + kStereoRow + 2.0, fullW, kStereoRow };
    }
    return r;
}

Result horizontal(const Input &in) {
    Result r;
    r.vertical = false;
    const double W = in.width - 2 * kPad, H = in.height - 2 * kPad;
    if (W <= 0 || H <= 0) return r;

    bool readouts = in.readouts, side = in.loudness || in.stereo, loudBars = in.loudness;
    const double labelW = kLabelSize;
    const double clipW = kClipSize + 4.0;
    auto barsLength = [&] {
        return W - labelW - (readouts ? kReadoutWidth : 0.0) - clipW - (side ? kStatsWidth + 10.0 : 0.0);
    };
    if (barsLength() < kMinHorizontalBars * 2) side = false;
    if (barsLength() < kMinHorizontalBars) readouts = false;
    const double barsW = std::max(0.0, barsLength());

    double barH = 0.0;
    auto fit = [&] {
        const int n = loudBars ? 4 : 2;
        const double fixed = kScaleHeight + (loudBars ? 6.0 + kPairGap : 0.0);
        barH = std::min(kMaxBarHeight, (H - fixed) / n);
    };
    fit();
    if (loudBars && barH < 4.0) { loudBars = false; fit(); }
    barH = std::floor(std::max(barH, 1.0));

    const double contentH = loudBars ? 4 * barH + kScaleHeight + 6.0 + kPairGap : 2 * barH + kScaleHeight;
    const double y0 = std::round(kPad + (H - contentH) / 2.0);
    const double barsX = kPad + labelW;

    double ys[BarCount];
    ys[BarL] = y0;
    ys[BarR] = y0 + barH + kScaleHeight;
    ys[BarM] = ys[BarR] + barH + 6.0;
    ys[BarS] = ys[BarM] + barH + kPairGap;
    const int bars = loudBars ? 4 : 2;
    for (int i = 0; i < bars; ++i) {
        r.bar[i] = { barsX, ys[i], barsW, barH };
        r.label[i] = { kPad, ys[i] + barH / 2.0 - kLabelSize / 2.0, labelW, kLabelSize };
        if (readouts) r.readout[i] = { barsX + barsW + 2.0, ys[i] + barH / 2.0 - kReadoutHeight / 2.0,
                                       kReadoutWidth - 2.0, kReadoutHeight };
    }
    const double clipX = barsX + barsW + (readouts ? kReadoutWidth : 0.0) + 2.0;
    for (int c = 0; c < 2; ++c) {
        const double ch = std::min(barH, kClipSize + 4.0);
        r.clip[c] = { clipX, ys[c] + (barH - ch) / 2.0, kClipSize, ch };
    }
    r.scale = { barsX, ys[BarL] + barH, barsW, kScaleHeight };

    if (side) {
        const double sx = kPad + W - kStatsWidth;
        double y = kPad;
        if (in.loudness) {
            r.stats = { sx, y, kStatsWidth, kStatsHeight - 2.0 };
            r.statsTwoColumns = true;
            y += kStatsHeight;
        }
        if (in.stereo && y + kStereoHeight <= kPad + H + 0.5) {
            r.correlation = { sx, y + 2.0, kStatsWidth, kStereoRow };
            r.balance = { sx, y + 2.0 + kStereoRow + 2.0, kStatsWidth, kStereoRow };
        }
    }
    return r;
}

} // namespace

Result layout(const Input &in) {
    bool vert;
    switch (in.orientation) {
        case meter::Orientation::Vertical:   vert = true; break;
        case meter::Orientation::Horizontal: vert = false; break;
        default:
            // Bars run along the longer side; square-ish panels stay upright.
            vert = in.height * 1.4 >= in.width;
            break;
    }
    return vert ? vertical(in) : horizontal(in);
}

} // namespace meter_layout
