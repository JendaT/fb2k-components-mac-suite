//
//  OverlayText.h
//  foo_wave_seekbar_mac
//
//  Number and time formatting for the overlays and scales, and where the
//  hover readout goes. Numbers use the Unicode minus (U+2212). Header-only,
//  tested standalone.
//

#pragma once

#include <cmath>
#include <cstdio>
#include <string>

namespace overlay {

// Hover readout box, in points at the 10 pt text size (scaled with the text)
constexpr double kReadoutWidth = 186.0;
constexpr double kReadoutTop = 10.0;        // from the top edge
constexpr double kReadoutGap = 10.0;        // from the mouse
constexpr double kReadoutFlipMargin = 24.0; // past the box: it goes left this close to the right edge

// "−12.4", "+0.72" with `plus`, "0.0" for anything that rounds to zero,
// "−∞" / "+∞", and "—" for NaN (undefined, e.g. correlation of silence).
inline std::string formatNumber(double v, int decimals, bool plus = false) {
    if (std::isnan(v)) return "—";
    if (std::isinf(v)) return v < 0 ? "−∞" : "+∞";
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.*f", decimals, std::fabs(v));
    const double rounded = std::atof(buf);
    if (rounded == 0.0) return buf;
    if (v < 0) return std::string("−") + buf;
    return plus ? std::string("+") + buf : std::string(buf);
}

// m:ss, or m:ss.s with `tenths` (tenths truncate, so 59.96 is 0:59.9);
// h:mm:ss from an hour on.
inline std::string formatClock(double seconds, bool tenths = false) {
    if (!(seconds > 0.0)) seconds = 0.0;
    const double t = tenths ? std::floor(seconds * 10.0 + 1e-9) / 10.0 : std::floor(seconds);
    const long whole = (long)t;
    const long h = whole / 3600, m = (whole / 60) % 60;
    const double s = t - (double)(whole - whole % 60);
    char buf[32];
    if (h > 0) {
        if (tenths) std::snprintf(buf, sizeof buf, "%ld:%02ld:%04.1f", h, m, s);
        else std::snprintf(buf, sizeof buf, "%ld:%02ld:%02ld", h, m, whole % 60);
    } else {
        if (tenths) std::snprintf(buf, sizeof buf, "%ld:%04.1f", whole / 60, s);
        else std::snprintf(buf, sizeof buf, "%ld:%02ld", whole / 60, whole % 60);
    }
    return buf;
}

// Time ruler: the smallest major interval (seconds) that keeps labels at
// least kRulerLabelSpacing points apart. Minor ticks go at a quarter of it.
// Past the spec's 10 min, longer intervals keep long mixes readable.
constexpr double kRulerLabelSpacing = 110.0;
constexpr double kRulerIntervals[] = { 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600 };

inline double rulerInterval(double durationSeconds, double widthPoints) {
    if (!(durationSeconds > 0.0) || !(widthPoints > 0.0)) return kRulerIntervals[0];
    const double pointsPerSecond = widthPoints / durationSeconds;
    for (double interval : kRulerIntervals) {
        if (interval * pointsPerSecond >= kRulerLabelSpacing) return interval;
    }
    return kRulerIntervals[sizeof kRulerIntervals / sizeof kRulerIntervals[0] - 1];
}

// Left edge of the readout box: right of the mouse, or left of it near the
// right edge (within the box's width plus a margin), and never off the
// view's left.
inline double readoutX(double mouseX, double viewWidth, double boxWidth = kReadoutWidth) {
    const double flipZone = boxWidth + kReadoutFlipMargin;
    double x = mouseX > viewWidth - flipZone ? mouseX - kReadoutGap - boxWidth : mouseX + kReadoutGap;
    return std::fmax(0.0, x);
}

} // namespace overlay
