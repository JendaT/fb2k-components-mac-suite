//
//  WaveformColorMap.h
//  foo_wave_seekbar_mac
//
//  Pure color math: amplitude and position colour ramps, ARGB packing, and
//  the animation phase driving the cursor effects.
//
//  Extracted from WaveformSeekbarView and WaveformPreferences, which each had
//  their own copy of the ARGB conversion. Header-only, SDK-free and
//  AppKit-free - components are plain 0..1 doubles that callers wrap in an
//  NSColor or hand straight to CGContext.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace waveseek {

// Colour components in 0..1, matching what NSColor and CGContext expect.
struct Rgb {
    double r = 0.0;
    double g = 0.0;
    double b = 0.0;
};

struct Rgba {
    double r = 0.0;
    double g = 0.0;
    double b = 0.0;
    double a = 1.0;
};

// Heat map: quiet to loud as blue -> cyan -> green -> yellow -> red, in four
// equal linear segments.
inline Rgb heatMapColor(double amplitude) {
    amplitude = std::max(0.0, std::min(1.0, amplitude));

    if (amplitude < 0.25) {
        double t = amplitude / 0.25;
        return {0.0, t, 1.0};
    }
    if (amplitude < 0.5) {
        double t = (amplitude - 0.25) / 0.25;
        return {0.0, 1.0, 1.0 - t};
    }
    if (amplitude < 0.75) {
        double t = (amplitude - 0.5) / 0.25;
        return {t, 1.0, 0.0};
    }
    double t = (amplitude - 0.75) / 0.25;
    return {1.0, 1.0 - t, 0.0};
}

// Rainbow: position drives hue through a full turn at full saturation and
// value. Positions outside 0..1 wrap.
inline Rgb rainbowColor(double position) {
    double hue = std::fmod(position, 1.0);
    if (hue < 0.0) hue += 1.0;

    const double saturation = 1.0;
    const double value = 1.0;

    int sextant = static_cast<int>(hue * 6.0) % 6;
    double f = hue * 6.0 - std::floor(hue * 6.0);
    double p = value * (1.0 - saturation);
    double q = value * (1.0 - f * saturation);
    double t = value * (1.0 - (1.0 - f) * saturation);

    switch (sextant) {
        case 0:  return {value, t, p};
        case 1:  return {q, value, p};
        case 2:  return {p, value, t};
        case 3:  return {p, q, value};
        case 4:  return {t, p, value};
        default: return {value, p, q};
    }
}

// Config stores colours as packed 0xAARRGGBB.
inline Rgba rgbaFromArgb(uint32_t argb) {
    return {
        ((argb >> 16) & 0xFF) / 255.0,
        ((argb >> 8) & 0xFF) / 255.0,
        (argb & 0xFF) / 255.0,
        ((argb >> 24) & 0xFF) / 255.0
    };
}

// Rounds rather than truncates: 51/255 comes back as 50.999... on some
// values, and truncating there would walk a colour down by one step every
// time preferences were saved and reloaded.
inline uint32_t argbFromRgba(const Rgba& color) {
    auto channel = [](double v) -> uint32_t {
        double clamped = std::max(0.0, std::min(1.0, v));
        return static_cast<uint32_t>(std::lround(clamped * 255.0)) & 0xFF;
    };
    return (channel(color.a) << 24) | (channel(color.r) << 16) |
           (channel(color.g) << 8) | channel(color.b);
}

// Cursor animation speed: locked to the track's tempo when BPM sync is on and
// a tempo is known, otherwise the effect's own rate.
inline double animationFrequency(bool bpmSync, double trackBpm, double defaultHz) {
    if (bpmSync && trackBpm > 0.0) {
        return trackBpm / 60.0;
    }
    return defaultHz;
}

// Effects share one oscillator: a 0..1 sine at the given rate. Callers scale
// it into an alpha, a width, or an offset.
inline double oscillator(double timeSeconds, double frequencyHz, double phase = 0.0) {
    return 0.5 + 0.5 * std::sin(timeSeconds * frequencyHz * 2.0 * M_PI + phase);
}

} // namespace waveseek
