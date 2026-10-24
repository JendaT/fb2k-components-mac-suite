//
//  MeterScale.cpp
//  foo_jl_levelmeter_mac
//

#include "MeterScale.h"
#include <algorithm>
#include <cmath>

namespace meter {

namespace {

// Extended spacing: the IEC 60268-18 style piecewise scale, 0..100 over
// -70..0 dB, with 2.5 units/dB over the top 20 dB.
double extended(double db) {
    if (db < -70.0) return 0.0;
    if (db < -60.0) return (db + 70.0) * 0.25;
    if (db < -50.0) return (db + 60.0) * 0.5 + 2.5;
    if (db < -40.0) return (db + 50.0) * 0.75 + 7.5;
    if (db < -30.0) return (db + 40.0) * 1.5 + 15.0;
    if (db < -20.0) return (db + 30.0) * 2.0 + 30.0;
    if (db < 0.0)   return (db + 20.0) * 2.5 + 50.0;
    return 100.0 + db * 2.5;
}

} // namespace

BarScale::BarScale(double floorDb, ScaleSpacing spacing, double kReference)
    : _floor(std::min(floorDb, -6.0)), _spacing(spacing), _kRef(kReference) {
    _rawFloor = raw(_floor);
    _rawTop = raw(0.0);
}

double BarScale::raw(double db) const {
    return _spacing == ScaleSpacing::Extended ? extended(db) : db;
}

double BarScale::position(double db) const {
    if (!(db > _floor)) return 0.0;
    if (db >= 0.0) return 1.0;
    return (raw(db) - _rawFloor) / (_rawTop - _rawFloor);
}

std::vector<BarScale::Tick> BarScale::ticks(double lengthPx, double labelPx) const {
    std::vector<Tick> out;
    if (lengthPx <= 0) return out;

    // Labels are counted from the K reference, so K-20 reads +4, 0, -4 ...
    // rather than -16, -20, -24. They are placed from the top down with the
    // finest step that fits there; where the scale compresses the step grows
    // along a ladder of round numbers, labelling only multiples of it.
    static const int kLadder[] = { 1, 2, 5, 10, 20, 30 };
    const int kLadderSize = (int)(sizeof(kLadder) / sizeof(kLadder[0]));
    const double top = 0.0 - _kRef;               // label value at 0 dBFS
    const double bottom = _floor - _kRef;
    auto pxOf = [&](double v) { return (1.0 - position(v + _kRef)) * lengthPx; };

    // Start with the finest step whose first gap below the top fits.
    int rung = 0;
    const int topLabel = (int)std::floor(top);
    while (rung < kLadderSize - 1) {
        const int s = kLadder[rung];
        const int next = (int)std::floor((topLabel - 1) / (double)s) * s;
        if (pxOf(next) - pxOf(topLabel) >= labelPx) break;
        ++rung;
    }

    int v = topLabel;
    out.push_back({ v + _kRef, position(v + _kRef), v, true });
    double lastPx = pxOf(v);
    int minorStep = kLadder[rung];
    while (true) {
        const int s = kLadder[rung];
        const int next = (int)std::floor((v - 1) / (double)s) * s;
        if (next < bottom - 1e-9) break;
        if (pxOf(next) - lastPx >= labelPx) {
            // Unlabelled ticks at the finer step in between, where they fit.
            for (int m = (int)std::floor((v - 1) / (double)minorStep) * minorStep; m > next; m -= minorStep) {
                const double mpx = pxOf(m);
                if (mpx - pxOf(v) >= 3.0 && pxOf(next) - mpx >= 3.0) {
                    out.push_back({ m + _kRef, position(m + _kRef), m, false });
                }
            }
            out.push_back({ next + _kRef, position(next + _kRef), next, true });
            lastPx = pxOf(next);
            minorStep = s;
            v = next;
        } else if (rung < kLadderSize - 1) {
            ++rung;
        } else {
            break;
        }
    }
    return out;
}

namespace vu_face {

double fraction(double vu) {
    // Amplitude relative to +3 VU.
    if (vu <= -60.0) return 0.0;
    return std::pow(10.0, (vu - kTopVu) / 20.0);
}

double percentFraction(double percent) {
    return (percent / 100.0) / std::pow(10.0, kTopVu / 20.0);
}

const std::vector<double> &majorMarks() {
    static const std::vector<double> marks = { -20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3 };
    return marks;
}

const std::vector<double> &minorMarks() {
    static const std::vector<double> marks = { -15, -8, -6, -4, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5 };
    return marks;
}

} // namespace vu_face

} // namespace meter
