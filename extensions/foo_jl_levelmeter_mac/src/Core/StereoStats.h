//
//  StereoStats.h
//  foo_jl_levelmeter_mac
//
//  Phase correlation and left/right balance from exponentially averaged
//  channel products. Pure C++, no SDK.
//

#pragma once

#include <algorithm>
#include <cmath>

namespace meter {

class StereoStats {
public:
    // Readings below this mean square (about -60 dBFS RMS) count as silence.
    static constexpr double kSilentEnergy = 1e-6;
    static constexpr float kMaxBalanceDb = 40.0f;

    void configure(double sampleRate, double seconds) {
        const double sr = sampleRate > 0 ? sampleRate : 48000.0;
        _k = 1.0 - std::exp(-1.0 / (std::max(seconds, 0.01) * sr));
    }
    void reset() { _ll = _rr = _lr = 0.0; }

    inline void push(float l, float r) {
        _ll += ((double)l * l - _ll) * _k;
        _rr += ((double)r * r - _rr) * _k;
        _lr += ((double)l * r - _lr) * _k;
    }

    bool silent() const { return _ll + _rr < 2.0 * kSilentEnergy; }

    // +1 mono, 0 unrelated, -1 polarity inverted. A channel that is silent
    // on its own reads 0: there is nothing for it to correlate with.
    float correlation() const {
        if (silent()) return 0.0f;
        const double d = std::sqrt(_ll * _rr);
        if (d < kSilentEnergy * 1e-3) return 0.0f;
        return (float)std::max(-1.0, std::min(1.0, _lr / d));
    }

    // Right minus left level in dB: positive leans right.
    float balanceDb() const {
        if (silent()) return 0.0f;
        const double l = std::max(_ll, 1e-12), r = std::max(_rr, 1e-12);
        const float db = (float)(10.0 * std::log10(r / l));
        return std::max(-kMaxBalanceDb, std::min(kMaxBalanceDb, db));
    }

private:
    double _k = 0.0;
    double _ll = 0.0, _rr = 0.0, _lr = 0.0;
};

} // namespace meter
