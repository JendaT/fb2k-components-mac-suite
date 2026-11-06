//
//  WaveformGeometry.h
//  foo_wave_seekbar_mac
//
//  Pure render geometry: bucket-to-pixel mapping, channel layout, gradient
//  band ranges, and pointer-to-seek conversion.
//
//  Extracted from WaveformSeekbarView so the math can be unit-tested without
//  an NSView or a CGContext. Header-only, SDK-free and AppKit-free: plain
//  doubles in, plain doubles out. The view keeps the drawing; this owns the
//  numbers it draws with.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace waveseek {

// Vertical breathing room between a channel's peak and the view edge.
constexpr double kWaveformPadding = 4.0;

// Where a channel's baseline sits and how far a full-scale peak reaches from
// it. Both stereo halves and the mono full-height layout reduce to this.
struct ChannelLayout {
    double centerY = 0.0;
    double amplitude = 0.0;
};

// Stereo: left occupies the upper half, right the lower, each symmetric about
// its own center. (macOS coordinates are bottom-left origin, so 0.75 is the
// visually upper band.)
inline ChannelLayout stereoLeftLayout(double viewHeight, double padding = kWaveformPadding) {
    return {viewHeight * 0.75, (viewHeight / 4.0) - padding};
}

inline ChannelLayout stereoRightLayout(double viewHeight, double padding = kWaveformPadding) {
    return {viewHeight * 0.25, (viewHeight / 4.0) - padding};
}

inline ChannelLayout monoLayout(double viewHeight, double padding = kWaveformPadding) {
    return {viewHeight / 2.0, (viewHeight / 2.0) - padding};
}

// Left edge of bucket i.
inline double bucketX(size_t index, size_t bucketCount, double viewWidth) {
    if (bucketCount == 0) return 0.0;
    return (static_cast<double>(index) / static_cast<double>(bucketCount)) * viewWidth;
}

// Bucket position along the track in 0..1 - the rainbow style's hue input.
inline double bucketPosition(size_t index, size_t bucketCount) {
    if (bucketCount == 0) return 0.0;
    return static_cast<double>(index) / static_cast<double>(bucketCount);
}

// Deflection drawn for a bucket: the larger of the two excursions, so a
// one-sided waveform still renders at its true height.
inline double peakAmplitude(double minValue, double maxValue) {
    return std::max(std::abs(minValue), std::abs(maxValue));
}

struct MinMax {
    double min = 0.0;
    double max = 0.0;
};

// Two ways to fold stereo into one trace. They are NOT interchangeable:
// envelope keeps the outer bound of both channels, average sums them like a
// real mono downmix and so reads lower on wide-stereo material. The view uses
// envelope for the per-bucket-color styles and average for solid; preserved
// here rather than unified, since either choice changes what users see.
inline MinMax monoDownmixEnvelope(double min0, double max0, double min1, double max1) {
    return {std::min(min0, min1), std::max(max0, max1)};
}

inline MinMax monoDownmixAverage(double min0, double max0, double min1, double max1) {
    return {(min0 + min1) * 0.5, (max0 + max1) * 0.5};
}

// Solid style stacks translucent bands from the baseline outward; each band
// draws only the slice of a peak that falls inside it.
struct BandRange {
    double start = 0.0;
    double end = 0.0;
};

inline BandRange bandRange(int band, int bandCount) {
    if (bandCount <= 0) return {0.0, 1.0};
    return {static_cast<double>(band) / bandCount,
            static_cast<double>(band + 1) / bandCount};
}

// Bands fade as they move away from the baseline, down to 0.4 at full scale.
inline double bandAlpha(int band, int bandCount) {
    return 1.0 - (bandRange(band, bandCount).start * 0.6);
}

// 0 means "no gradient, draw a flat trace"; above 32 the bands are thinner
// than a pixel and only cost fill rate.
inline int clampGradientBands(int bands) {
    return std::min(32, bands);
}

// Width of the soft edge trailing the cursor, capped so it stays a highlight
// rather than washing out a wide view.
inline double cursorFadeWidth(double viewWidth) {
    return std::min(viewWidth * 0.02, 10.0);
}

// Pointer x to track position, clamped so a drag past either edge pins to the
// track's start or end instead of seeking out of bounds.
inline double normalizedPositionForX(double x, double viewWidth) {
    if (viewWidth <= 0.0) return 0.0;
    return std::max(0.0, std::min(1.0, x / viewWidth));
}

inline double seekTimeForPosition(double normalizedPosition, double duration) {
    return normalizedPosition * duration;
}

// Position step for an accessibility increment/decrement, clamped to the
// track. Returns the current position unchanged when there is no duration.
inline double nudgedPosition(double position, double duration, double seconds) {
    if (duration <= 0.0) return position;
    return std::max(0.0, std::min(1.0, position + (seconds / duration)));
}

// The 60fps timer only repaints once the cursor would actually move: a
// quarter pixel of travel, expressed in normalized position.
inline double positionRedrawThreshold(double viewWidth) {
    return (viewWidth > 1.0) ? (0.25 / viewWidth) : 0.001;
}

} // namespace waveseek
