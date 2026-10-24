//
//  MeterLayout.h
//  foo_jl_levelmeter_mac
//
//  Places the digital meter's parts in the panel. Top-left origin, points.
//  Sections drop out in a fixed order when the panel is too small: balance,
//  correlation, loudness figures, readouts, then the loudness bars, so the
//  level bars always get the room. Pure C++, no SDK.
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
    bool correlation = true;
    bool balance = true;
    double text = 1.0;        // text size relative to the default (10 pt readouts)
};

// Sizes of the parts that hold text; they grow with the text size.
struct Metrics {
    double text = 1.0;
    double readoutHeight = 14.0;
    double readoutWidth = 40.0;
    double labelSize = 12.0;
    double scaleWidth = 26.0;     // vertical scale column
    double scaleHeight = 12.0;    // horizontal scale row
    double statsRow = 14.0;
    double stereoRow = 13.0;      // one stereo bar plus its labels
    double statsWidth = 190.0;    // horizontal layout stats column

    static Metrics forText(double t) {
        t = t < 0.5 ? 0.5 : (t > 2.0 ? 2.0 : t);
        Metrics m;
        m.text = t;
        m.readoutHeight *= t; m.readoutWidth *= t; m.labelSize *= t;
        m.scaleWidth *= t; m.scaleHeight *= t; m.statsRow *= t;
        m.stereoRow *= t; m.statsWidth *= t;
        return m;
    }
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
    Metrics m;                // the text-dependent sizes used
};

// Fixed sizes (the text-dependent ones are in Metrics).
constexpr double kPad = 6.0;
constexpr double kClipSize = 6.0;
constexpr double kMaxBarWidth = 56.0;
constexpr double kMaxBarHeight = 18.0;    // horizontal bars

Result layout(const Input &in);

} // namespace meter_layout
