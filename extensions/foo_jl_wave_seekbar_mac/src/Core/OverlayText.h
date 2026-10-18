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

// Hover readout box, in points
constexpr double kReadoutWidth = 186.0;
constexpr double kReadoutTop = 10.0;        // from the top edge
constexpr double kReadoutGap = 10.0;        // from the mouse
constexpr double kReadoutFlipZone = 210.0;  // this close to the right edge, it goes left

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

// Left edge of the readout box: right of the mouse, or left of it near the
// right edge, and never off the view's left.
inline double readoutX(double mouseX, double viewWidth) {
    double x = mouseX > viewWidth - kReadoutFlipZone ? mouseX - kReadoutGap - kReadoutWidth
                                                     : mouseX + kReadoutGap;
    return std::fmax(0.0, x);
}

} // namespace overlay
