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
double statsHeight(const Metrics &m) { return 2 * m.statsRow + 4.0; }
// Height of `rows` stereo bars (correlation, balance) with their spacing.
double stereoHeight(const Metrics &m, int rows) { return rows > 0 ? rows * (m.stereoRow + 2.0) : 0.0; }

// Lay out the enabled stereo rows from y down: correlation, then balance.
void placeStereo(Result &r, bool correlation, bool balance, double x, double y, double w) {
    const Metrics &m = r.m;
    y += 2.0;
    if (correlation) { r.correlation = { x, y, w, m.stereoRow }; y += m.stereoRow + 2.0; }
    if (balance) r.balance = { x, y, w, m.stereoRow };
}

Result vertical(const Input &in) {
    Result r;
    r.vertical = true;
    r.m = Metrics::forText(in.text);
    const Metrics &m = r.m;
    const double W = in.width - 2 * kPad, H = in.height - 2 * kPad;
    if (W <= 0 || H <= 0) return r;

    bool readouts = in.readouts, stats = in.loudness, loudBars = in.loudness;
    bool correlation = in.correlation, balance = in.balance;
    const double clipH = kClipSize + 3.0;
    const double labelH = m.labelSize + 2.0;
    auto barsLength = [&] {
        return H - (readouts ? m.readoutHeight + 2.0 : 0.0) - clipH - labelH -
               (stats ? statsHeight(m) : 0.0) - stereoHeight(m, (int)correlation + (int)balance);
    };
    // Short panels give up the extras before the bars get too short.
    if (barsLength() < kMinBarsLength) balance = false;
    if (barsLength() < kMinBarsLength) correlation = false;
    if (barsLength() < kMinBarsLength) stats = false;
    if (barsLength() < kMinBarsLength) readouts = false;
    const double barsH = std::max(0.0, barsLength());

    // Bar widths: all four equal, capped so wide panels don't get slabs.
    double barW = 0.0;
    auto fit = [&] {
        if (loudBars) {
            const double fixed = 2 * m.scaleWidth + kGroupGap + kPairGap;
            barW = std::min(kMaxBarWidth, (W - fixed) / 4.0);
        } else {
            barW = std::min(kMaxBarWidth, (W - m.scaleWidth) / 2.0);
        }
    };
    fit();
    if (loudBars && barW < 6.0) { loudBars = false; fit(); }
    barW = std::floor(std::max(barW, 1.0));

    const double contentW = loudBars ? 4 * barW + 2 * m.scaleWidth + kGroupGap + kPairGap
                                     : 2 * barW + m.scaleWidth;
    const double x0 = std::round(kPad + (W - contentW) / 2.0);
    double y = kPad;

    const double readoutY = y;
    if (readouts) y += m.readoutHeight + 2.0;
    const double clipY = y;
    y += clipH;
    const double barsY = y;
    y += barsH;
    const double labelY = y + 2.0;
    y += labelH;

    double xs[BarCount];
    xs[BarL] = x0;
    xs[BarR] = x0 + barW + m.scaleWidth;
    xs[BarM] = xs[BarR] + barW + kGroupGap;
    xs[BarS] = xs[BarM] + barW + kPairGap;
    const int bars = loudBars ? 4 : 2;
    for (int i = 0; i < bars; ++i) {
        r.bar[i] = { xs[i], barsY, barW, barsH };
        r.label[i] = { xs[i] - 4, labelY, barW + 8, m.labelSize };
        // Loudness numbers have only the narrow pair gap to spill into.
        if (readouts && (i <= BarR || barW >= 26.0 * m.text)) {
            // Numbers may be wider than a thin bar: let them spill into the gaps.
            const double spill = i == BarM || i == BarS ? kPairGap / 2.0 + 2.0 : 6.0;
            r.readout[i] = { xs[i] - spill, readoutY, barW + 2 * spill, m.readoutHeight };
        }
    }
    for (int c = 0; c < 2; ++c) {
        const double cw = std::min(barW, 18.0);
        r.clip[c] = { xs[c] + (barW - cw) / 2.0, clipY, cw, kClipSize };
    }
    r.scale = { xs[BarL] + barW, barsY, m.scaleWidth, barsH };
    if (loudBars) r.loudnessScale = { xs[BarS] + barW, barsY, m.scaleWidth, barsH };

    const double fullX = kPad, fullW = W;
    if (stats) {
        r.stats = { fullX, y + 2.0, fullW, statsHeight(m) - 2.0 };
        r.statsTwoColumns = fullW >= 150.0 * m.text;
        y += statsHeight(m);
    }
    placeStereo(r, correlation, balance, fullX, y, fullW);
    return r;
}

Result horizontal(const Input &in) {
    Result r;
    r.vertical = false;
    r.m = Metrics::forText(in.text);
    const Metrics &m = r.m;
    const double W = in.width - 2 * kPad, H = in.height - 2 * kPad;
    if (W <= 0 || H <= 0) return r;

    bool readouts = in.readouts, side = in.loudness || in.correlation || in.balance, loudBars = in.loudness;
    const double labelW = m.labelSize;
    const double clipW = kClipSize + 4.0;
    auto barsLength = [&] {
        return W - labelW - (readouts ? m.readoutWidth : 0.0) - clipW - (side ? m.statsWidth + 10.0 : 0.0);
    };
    if (barsLength() < kMinHorizontalBars * 2) side = false;
    if (barsLength() < kMinHorizontalBars) readouts = false;
    const double barsW = std::max(0.0, barsLength());

    double barH = 0.0;
    auto fit = [&] {
        const int n = loudBars ? 4 : 2;
        const double fixed = m.scaleHeight + (loudBars ? 6.0 + kPairGap : 0.0);
        barH = std::min(kMaxBarHeight, (H - fixed) / n);
    };
    fit();
    if (loudBars && barH < 4.0) { loudBars = false; fit(); }
    barH = std::floor(std::max(barH, 1.0));

    const double contentH = loudBars ? 4 * barH + m.scaleHeight + 6.0 + kPairGap : 2 * barH + m.scaleHeight;
    const double y0 = std::round(kPad + (H - contentH) / 2.0);
    const double barsX = kPad + labelW;

    double ys[BarCount];
    ys[BarL] = y0;
    ys[BarR] = y0 + barH + m.scaleHeight;
    ys[BarM] = ys[BarR] + barH + 6.0;
    ys[BarS] = ys[BarM] + barH + kPairGap;
    const int bars = loudBars ? 4 : 2;
    for (int i = 0; i < bars; ++i) {
        r.bar[i] = { barsX, ys[i], barsW, barH };
        // Text centred on its bar, but kept inside the panel when the
        // bar is thinner than the text.
        auto centred = [&](double h) { return std::max(0.0, std::min(in.height - h, ys[i] + barH / 2.0 - h / 2.0)); };
        r.label[i] = { kPad, centred(m.labelSize), labelW, m.labelSize };
        if (readouts) r.readout[i] = { barsX + barsW + 2.0, centred(m.readoutHeight), m.readoutWidth - 2.0, m.readoutHeight };
    }
    const double clipX = barsX + barsW + (readouts ? m.readoutWidth : 0.0) + 2.0;
    for (int c = 0; c < 2; ++c) {
        const double ch = std::min(barH, kClipSize + 4.0);
        r.clip[c] = { clipX, ys[c] + (barH - ch) / 2.0, kClipSize, ch };
    }
    r.scale = { barsX, ys[BarL] + barH, barsW, m.scaleHeight };

    if (side) {
        const double sx = kPad + W - m.statsWidth;
        double y = kPad;
        if (in.loudness) {
            r.stats = { sx, y, m.statsWidth, statsHeight(m) - 2.0 };
            r.statsTwoColumns = true;
            y += statsHeight(m);
        }
        // Whichever stereo rows fit under the figures, correlation first.
        bool correlation = in.correlation, balance = in.balance;
        const double room = kPad + H + 0.5 - y;
        if (stereoHeight(m, (int)correlation + (int)balance) > room) balance = false;
        if (stereoHeight(m, (int)correlation + (int)balance) > room) correlation = false;
        placeStereo(r, correlation, balance, sx, y, m.statsWidth);
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
