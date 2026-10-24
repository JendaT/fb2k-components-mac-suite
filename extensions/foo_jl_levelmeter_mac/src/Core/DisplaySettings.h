//
//  DisplaySettings.h
//  foo_jl_levelmeter_mac
//
//  Everything the renderer needs besides the readings: style, layout
//  choices, scale and resolved colours. Pure C++, no SDK, so the renderer
//  can be driven from tests and the preview tool.
//

#pragma once

#include "Detectors.h"
#include <cstdint>

namespace meter {

enum class MeterStyle : int {
    Digital = 0,   // bars, readouts, loudness and stereo figures
    Analog = 1,    // moving-coil needle faces
};

enum class Orientation : int {
    Auto = 0,
    Vertical = 1,
    Horizontal = 2,
};

enum class BarMode : int {
    PeakAndRms = 0,   // solid RMS with the peak above it, lighter
    Peak = 1,
    Rms = 2,
};

enum class ScaleType : int {
    Dbfs = 0,
    K20 = 1,   // 0 on the scale = -20 dBFS RMS
    K14 = 2,
    K12 = 3,
};

enum class ScaleSpacing : int {
    Linear = 0,     // even dB steps
    Extended = 1,   // more room near the top, compressed low end
};

enum class FaceStyle : int {
    Vintage = 0,   // warm backlit cream
    Dark = 1,      // black face, light markings
    Theme = 2,     // the component's colours
};

enum class NeedleLayout : int {
    Auto = 0,      // two faces side by side or stacked, whichever fits
    Pair = 1,      // two faces
    Single = 2,    // one face, two needles
};

// Resolved ARGB colours for the current appearance.
struct Palette {
    uint32_t background = 0xFF101214;
    uint32_t text = 0xFFC9CED4;     // scale labels, readouts
    uint32_t safe = 0xFF4CD964;     // level below the warning zone
    uint32_t warn = 0xFFFFB000;
    uint32_t over = 0xFFFF453A;
    uint32_t loudness = 0xFF4DA3F0; // momentary / short-term bars
    bool dark = true;
};

struct DisplaySettings {
    MeterStyle style = MeterStyle::Digital;
    Orientation orientation = Orientation::Auto;
    BarMode barMode = BarMode::PeakAndRms;
    ScaleType scale = ScaleType::Dbfs;
    ScaleSpacing spacing = ScaleSpacing::Extended;
    int floorDb = -60;              // bottom of the bar scale (dBFS)
    bool segments = false;          // LED-style segmented bars
    bool showReadouts = true;
    bool showLoudness = true;
    bool showStereo = true;
    bool truePeak = true;           // label peaks dBTP rather than dBFS
    double loudnessTarget = -14.0;  // LUFS marker on the loudness bars
    double warnDb = -12.0;          // dBFS where the warning colour starts (dBFS scale)
    double overDb = -3.0;           // dBFS where the over colour starts

    FaceStyle face = FaceStyle::Vintage;
    NeedleLayout needleLayout = NeedleLayout::Auto;
    NeedleBallistics needle = NeedleBallistics::VU;
    double referenceDbfs = -18.0;   // 0 VU
    bool peakLed = true;
    double peakLedDbfs = -1.0;      // peak LED threshold

    Palette palette;

    // dBFS level of the K-system reference, 0 for the plain dBFS scale.
    double kReference() const {
        switch (scale) {
            case ScaleType::K20: return -20.0;
            case ScaleType::K14: return -14.0;
            case ScaleType::K12: return -12.0;
            default:             return 0.0;
        }
    }
    // Zone boundaries in dBFS for the current scale. K-system scales use
    // their own: green to 0, yellow to +4, red above.
    double warnStart() const { return scale == ScaleType::Dbfs ? warnDb : kReference(); }
    double overStart() const { return scale == ScaleType::Dbfs ? overDb : kReference() + 4.0; }
};

} // namespace meter
