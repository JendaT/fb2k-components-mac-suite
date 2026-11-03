//
//  ZoomRange.h
//  foo_wave_seekbar_mac
//
//  The part of the track the waveform shows when zoomed in, as fractions of
//  the track: zoom about a point, pan, and the mapping between a point across
//  the waveform and a track position. Pure C++, tested standalone.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace waveseek {

// Zooms in until an analysis block spans this many points; past a block per
// pixel column the drawing only interpolates between blocks
constexpr double kMaxZoomPointsPerBlock = 4.0;

inline double maxZoomFor(size_t blocks, double widthPoints) {
    if (blocks == 0 || !(widthPoints > 0.0)) return 1.0;
    return std::max(1.0, blocks * kMaxZoomPointsPerBlock / widthPoints);
}

struct ZoomRange {
    double zoom = 1.0;      // the waveform shows 1 / zoom of the track
    double start = 0.0;     // track position at the left edge, 0 .. 1 - 1 / zoom

    bool zoomed() const { return zoom > 1.0; }
    double span() const { return 1.0 / zoom; }
    double end() const { return start + span(); }

    // Track position (0..1) at a fraction across the waveform, and back;
    // positions outside the range map outside 0..1
    double positionAt(double across) const { return start + across * span(); }
    double acrossOf(double position) const { return (position - start) * zoom; }

    // Zooms by `factor`, keeping the track position under `across` in place.
    // Stays within 1..maxZoom, except that a view zoomed past maxZoom (it
    // got narrower) keeps its zoom until zoomed out.
    void zoomBy(double factor, double across, double maxZoom) {
        if (!(factor > 0.0) || !std::isfinite(factor)) return;
        across = std::clamp(across, 0.0, 1.0);
        const double anchor = positionAt(across);
        const double limit = std::max({ 1.0, maxZoom, std::min(zoom, zoom * factor) });
        zoom = std::clamp(zoom * factor, 1.0, limit);
        start = anchor - across * span();
        clampStart();
    }

    // Moves by a fraction of the waveform's width; positive goes later
    void panBy(double across) {
        if (!std::isfinite(across)) return;
        start += across * span();
        clampStart();
    }

    void reset() { *this = ZoomRange(); }

    bool operator==(const ZoomRange& o) const { return zoom == o.zoom && start == o.start; }
    bool operator!=(const ZoomRange& o) const { return !(*this == o); }

private:
    void clampStart() { start = std::clamp(start, 0.0, 1.0 - span()); }
};

} // namespace waveseek
