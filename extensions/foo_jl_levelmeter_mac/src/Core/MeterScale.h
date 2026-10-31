//
//  MeterScale.h
//  foo_jl_levelmeter_mac
//
//  Maps levels to positions along a bar and picks the tick marks, and maps
//  needle readings to angles on the VU face. Pure C++, no SDK.
//

#pragma once

#include "DisplaySettings.h"
#include <vector>

namespace meter {

class BarScale {
public:
    BarScale(double floorDb, ScaleSpacing spacing, double kReference = 0.0);

    // 0 at the floor, 1 at 0 dBFS, clamped.
    double position(double db) const;

    struct Tick {
        double db;       // dBFS
        double pos;      // 0..1
        int label;       // number shown (relative to the K reference)
        bool major;      // labelled
    };
    // Ticks for a bar `lengthPx` long whose labels need `labelPx` each.
    // Labels never crowd: each is at least labelPx from its neighbours.
    std::vector<Tick> ticks(double lengthPx, double labelPx) const;

    double floorDb() const { return _floor; }

private:
    double raw(double db) const;

    double _floor;
    ScaleSpacing _spacing;
    double _kRef;
    double _rawFloor, _rawTop;
};

// VU face geometry: amplitude-linear scale from rest to +3 VU, as on a
// classic moving-coil face.
namespace vu_face {
    constexpr double kSweepDegrees = 96.0;   // rest to +3 VU
    constexpr double kTopVu = 3.0;

    // Fraction of the sweep for a reading in VU (dB re the reference). Rest
    // is 0, +3 VU is 1, the end stop a little past it.
    double fraction(double vu);

    // Needle angle in degrees from vertical, negative to the left.
    inline double angle(double vu) { return -kSweepDegrees / 2.0 + fraction(vu) * kSweepDegrees; }

    // Fraction for a percentage-of-0-VU marking (100% = 0 VU).
    double percentFraction(double percent);

    // Labelled VU markings, left to right.
    const std::vector<double> &majorMarks();
    // Unlabelled marks between them.
    const std::vector<double> &minorMarks();
}

} // namespace meter
