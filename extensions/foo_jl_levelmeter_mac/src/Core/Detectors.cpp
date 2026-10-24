//
//  Detectors.cpp
//  foo_jl_levelmeter_mac
//

#include "Detectors.h"
#include <algorithm>

namespace meter {

void RmsWindow::configure(double sampleRate, double seconds) {
    if (sampleRate == _sampleRate && seconds == _seconds && !_buf.empty()) return;
    _sampleRate = sampleRate;
    _seconds = seconds;
    const size_t n = (size_t)std::max(1.0, std::round(sampleRate * seconds));
    _buf.assign(n, 0.0f);
    _pos = 0;
    _filled = 0;
    _sinceRebuild = 0;
    _sum = 0.0;
}

void RmsWindow::reset() {
    std::fill(_buf.begin(), _buf.end(), 0.0f);
    _pos = 0;
    _filled = 0;
    _sinceRebuild = 0;
    _sum = 0.0;
}

void RmsWindow::rebuild() {
    double s = 0.0;
    for (float v : _buf) s += v;
    _sum = s;
    _sinceRebuild = 0;
}

void VuBallistics::configure(double sampleRate) {
    _dt = sampleRate > 0 ? 1.0 / sampleRate : 1.0 / 48000.0;
}

void QuasiPeak::configure(double sampleRate, double attackSeconds, double fallDbPerSecond) {
    const double sr = sampleRate > 0 ? sampleRate : 48000.0;
    _attack = 1.0 - std::exp(-1.0 / (std::max(attackSeconds, 1e-5) * sr));
    _release = std::pow(10.0, -fallDbPerSecond / 20.0 / sr);

    // Calibrate on half a second of a unit 1 kHz sine, averaging the last
    // millisecond to smooth out the ripple.
    double v = 0.0, sum = 0.0;
    const int n = (int)(sr * 0.5), tail = std::max(1, (int)(sr * 0.001));
    for (int i = 0; i < n; ++i) {
        const double r = std::fabs(std::sin(2.0 * 3.14159265358979323846 * 1000.0 * i / sr));
        if (r > v) v += (r - v) * _attack;
        else v *= _release;
        if (i >= n - tail) sum += v;
    }
    const double steady = sum / tail;
    _gain = steady > 0 ? 0.7071067811865476 / steady : 0.7071067811865476;
    _v = 0.0;
}

} // namespace meter
