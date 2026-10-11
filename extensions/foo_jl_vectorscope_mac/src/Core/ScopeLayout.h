//
//  ScopeLayout.h
//  foo_jl_vectorscope_mac
//
//  Panel geometry: where the scope square and the correlation meter sit for
//  each meter position, and the track of every correlation bar. Pure C++
//  (no SDK, no Cocoa) and header-only, so it is unit-tested standalone; the
//  view only draws what this returns.
//

#pragma once

#include <algorithm>
#include <cmath>

namespace scope_layout {

// Where the correlation meter sits relative to the scope. The values are
// stored in config and index the preferences popup; do not renumber.
enum MeterPosition {
    MeterAuto = 0,      // Bottom or right, whichever leaves the larger scope
    MeterBottom = 1,
    MeterTop = 2,
    MeterLeft = 3,
    MeterRight = 4
};

constexpr int    kMaxBars = 3;
constexpr double kPad = 6.0;              // around the scope square
constexpr double kLabelInset = 14.0;      // room for L / R / M / S outside the diamond
constexpr double kMinLabelSide = 120.0;
constexpr double kMinPlotRadius = 8.0;
constexpr double kMinMeterPanel = 90.0;   // panel smaller than this: scope only
constexpr double kMeterPad = 6.0;
constexpr double kBarGap = 5.0;           // between neighbouring bars
constexpr double kMinBarLength = 20.0;
constexpr double kMinMeterLength = 220.0; // meter stays this long beside a small scope

// Horizontal bars (meter above or below the scope)
constexpr double kScaleHeight = 12.0;     // "-1  0  +1" under the bars
constexpr double kRowLabelWidth = 26.0;   // "Lo" / "Mid" / "Hi" before a bar
constexpr double kReadoutWidth = 38.0;    // "+0.00" after a bar

// Vertical bars (meter beside the scope)
constexpr double kScaleWidth = 16.0;      // "+1 / 0 / -1" on the outer edge
constexpr double kLegendLine = 12.0;      // one "Lo  +0.00" line per bar, listed under the bars
constexpr double kLegendNameWidth = 20.0;
constexpr double kLegendValueWidth = 27.0;

// Origin bottom-left, y up (the view is not flipped).
struct Rect {
    double x = 0.0, y = 0.0, w = 0.0, h = 0.0;
    bool empty() const { return w <= 0.0 || h <= 0.0; }
};

struct Input {
    double width = 0.0, height = 0.0;   // panel size
    int    position = MeterAuto;
    bool   showMeter = true;
    int    bars = 1;                    // 1 broadband, 3 band bars
    double barThickness = 6.0;
    bool   labels = true;               // axis letters, scale and readouts
};

struct Result {
    Rect plot;                  // square the diamond is inscribed in; empty = hidden
    bool axisLabels = false;    // L / R / M / S fit around the diamond
    Rect meter;                 // strip reserved for the meter; empty = hidden
    int  position = MeterBottom;  // resolved, never MeterAuto
    bool vertical = false;      // bars run from -1 at the bottom to +1 at the top
    int  bars = 0;              // valid tracks; 0 when the meter is hidden
    Rect track[kMaxBars];
    Rect legend[kMaxBars];      // vertical with labels: each bar's name / readout line
};

// Layout for one concrete position (not MeterAuto).
inline Result layoutAt(const Input& in, int position) {
    Result out;
    out.position = position;
    out.vertical = position == MeterLeft || position == MeterRight;

    const int bars = std::max(1, std::min(in.bars, kMaxBars));
    const double pitch = in.barThickness + kBarGap;
    const double scale = !in.labels ? 0.0 : (out.vertical ? kScaleWidth : kScaleHeight);
    double extent = kMeterPad + bars * pitch + scale + kMeterPad;
    // Text on the bars' own axis: name and readout at the ends of a horizontal
    // bar; under vertical bars a legend, with the same room left above so
    // zero lines up with the scope's side axis.
    double text = 0.0;
    if (in.labels && out.vertical) {
        text = 2.0 * (bars * kLegendLine + 1.0);
        const double legend = (bars > 1 ? kLegendNameWidth : 0.0) + kLegendValueWidth;
        extent = std::max(extent, kMeterPad + legend + kMeterPad);
    } else if (in.labels) {
        text = (bars > 1 ? kRowLabelWidth : 0.0) + kReadoutWidth;
    }
    // The meter gives way when the panel is small, when it would crowd out
    // the scope, or when its bars would be too short to read.
    const double along = out.vertical ? in.height : in.width;
    const double across = out.vertical ? in.width : in.height;
    const bool meter = in.showMeter && in.width >= kMinMeterPanel && in.height >= kMinMeterPanel &&
                       across - extent >= 2.0 * (kPad + kMinPlotRadius) &&
                       std::min(along - 2.0 * kPad, kMinMeterLength) - text >= kMinBarLength;

    Rect area;   // what is left for the scope
    area.w = in.width;
    area.h = in.height;
    if (meter) {
        out.meter = area;
        switch (position) {
            case MeterTop:
                out.meter.y = in.height - extent; out.meter.h = extent;
                area.h -= extent;
                break;
            case MeterLeft:
                out.meter.w = extent;
                area.x = extent; area.w -= extent;
                break;
            case MeterRight:
                out.meter.x = in.width - extent; out.meter.w = extent;
                area.w -= extent;
                break;
            default:
                out.meter.h = extent;
                area.y = extent; area.h -= extent;
                break;
        }
    }

    const double side = std::min(area.w, area.h) - 2.0 * kPad;
    out.axisLabels = in.labels && side >= kMinLabelSide;
    const double r = std::floor(side / 2.0 - (out.axisLabels ? kLabelInset : 0.0));
    if (r >= kMinPlotRadius) {
        out.plot.x = std::round(area.x + area.w / 2.0) - r;
        out.plot.y = std::round(area.y + area.h / 2.0) - r;
        out.plot.w = out.plot.h = 2.0 * r;
    }
    if (!meter) return out;

    // The meter is as long as the scope, but never cramped beside a small one.
    if (out.vertical) {
        const double total = std::min(in.height - 2.0 * kPad,
                                      std::max(out.plot.h + 2.0 * kLabelInset, kMinMeterLength));
        const double length = 2.0 * std::floor((total - text) / 2.0);
        const double bottom = std::round(in.height / 2.0) - length / 2.0;
        // Bars sit next to the scope, the scale on the outer edge.
        const double first = out.meter.x + kMeterPad + ((in.labels && position == MeterLeft) ? kScaleWidth : 0.0);
        for (int i = 0; i < bars; ++i) {
            out.track[i].x = std::round(first + (i + 0.5) * pitch - in.barThickness / 2.0);
            out.track[i].y = bottom;
            out.track[i].w = in.barThickness;
            out.track[i].h = length;
            if (in.labels) {
                out.legend[i].x = out.meter.x + kMeterPad;
                out.legend[i].y = bottom - 1.0 - (i + 1) * kLegendLine;
                out.legend[i].w = out.meter.w - 2.0 * kMeterPad;
                out.legend[i].h = kLegendLine;
            }
        }
    } else {
        const double total = std::min(in.width - 2.0 * kPad,
                                      std::max(out.plot.w + 2.0 * kLabelInset, kMinMeterLength));
        const double left = std::round(in.width / 2.0 - total / 2.0);
        const double barL = left + ((in.labels && bars > 1) ? kRowLabelWidth : 0.0);
        const double barR = left + total - (in.labels ? kReadoutWidth : 0.0);
        const double top = out.meter.y + out.meter.h - kMeterPad;
        for (int i = 0; i < bars; ++i) {
            out.track[i].x = barL;
            out.track[i].y = top - (i + 1) * pitch + kBarGap / 2.0;
            out.track[i].w = barR - barL;
            out.track[i].h = in.barThickness;
        }
    }
    out.bars = bars;
    return out;
}

inline Result layout(const Input& in) {
    if (in.position != MeterAuto) {
        const bool known = in.position >= MeterBottom && in.position <= MeterRight;
        return layoutAt(in, known ? in.position : MeterBottom);
    }
    const Result below = layoutAt(in, MeterBottom);
    const Result beside = layoutAt(in, MeterRight);
    // A placement that keeps the meter beats one that had to drop it.
    if (below.meter.empty() != beside.meter.empty()) return below.meter.empty() ? beside : below;
    return beside.plot.w > below.plot.w ? beside : below;
}

} // namespace scope_layout
