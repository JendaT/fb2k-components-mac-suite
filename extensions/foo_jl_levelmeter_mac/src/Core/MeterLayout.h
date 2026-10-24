//
//  MeterLayout.h
//  foo_jl_levelmeter_mac
//
//  Places the digital meter's parts in the panel. Top-left origin, points.
//  Sections drop out in a fixed order when the panel is too small: stereo
//  bars, then loudness figures, then readouts, then the loudness bars, so
//  the level bars always get the room. Pure C++, no SDK.
//

#pragma once

#include "DisplaySettings.h"

namespace meter_layout {

struct Rect {
    double x = 0, y = 0, w = 0, h = 0;
    bool empty() const { return w <= 0 || h <= 0; }
    double maxX() const { return x + w; }
    double maxY() const { return y + h; }
};

enum BarIndex { BarL = 0, BarR = 1, BarM = 2, BarS = 3, BarCount = 4 };

struct Input {
    double width = 0;
    double height = 0;
    meter::Orientation orientation = meter::Orientation::Auto;
    bool readouts = true;
    bool loudness = true;
    bool stereo = true;
};

struct Result {
    bool vertical = true;
    Rect bar[BarCount];       // M and S empty without loudness
    Rect readout[BarCount];   // number for each bar
    Rect label[BarCount];     // "L" "R" "M" "S"
    Rect clip[2];             // clip lights for L and R
    Rect scale;               // level scale (between L and R)
    Rect loudnessScale;       // vertical only: beside S
    Rect stats;               // integrated, range, true peak, PLR
    Rect correlation;
    Rect balance;
    bool statsTwoColumns = true;
};

// Sizes shared with the renderer.
constexpr double kPad = 6.0;
constexpr double kReadoutHeight = 14.0;
constexpr double kReadoutWidth = 40.0;
constexpr double kClipSize = 6.0;
constexpr double kLabelSize = 12.0;
constexpr double kScaleWidth = 26.0;      // vertical scale column
constexpr double kScaleHeight = 12.0;     // horizontal scale row
constexpr double kStatsRow = 14.0;
constexpr double kStereoRow = 13.0;       // one stereo bar plus its labels
constexpr double kStatsWidth = 190.0;     // horizontal layout stats column
constexpr double kMaxBarWidth = 56.0;
constexpr double kMaxBarHeight = 18.0;    // horizontal bars

Result layout(const Input &in);

} // namespace meter_layout
