//
//  Detectors.h
//  foo_jl_levelmeter_mac
//
//  Per-sample level detectors: sliding-window RMS, the moving-coil VU
//  movement and quasi-peak (PPM) rectifiers. Pure C++, no SDK.
//
//  All levels are linear amplitudes (1.0 = digital full scale). The VU and
//  PPM readings are calibrated so a steady sine reads its RMS value, which
//  makes "0 VU = -18 dBFS" mean "a sine at -18 dBFS RMS reads 0 VU".
//

#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

namespace meter {

// Silence in dB. Kept finite so arithmetic on readings stays well defined.
constexpr float kFloorDb = -200.0f;

inline float linearToDb(double v) {
    return v > 1e-10 ? (float)(20.0 * std::log10(v)) : kFloorDb;
}

inline double dbToLinear(double db) {
    return std::pow(10.0, db / 20.0);
}

// Mean square over a sliding window of the last N samples.
class RmsWindow {
public:
    void configure(double sampleRate, double seconds);
    void reset();

    inline void push(float x) {
        const float sq = x * x;
        _sum += (double)sq - (double)_buf[_pos];
        _buf[_pos] = sq;
        if (++_pos == _buf.size()) _pos = 0;
        if (_filled < _buf.size()) ++_filled;
        // The running sum drifts with rounding; rebuild it now and then.
        if (++_sinceRebuild >= _buf.size() * 8) rebuild();
    }

    // Mean over the full window; a partly filled window counts the missing
    // samples as silence so the reading rises like a real meter.
    double meanSquare() const {
        return _buf.empty() ? 0.0 : std::fmax(_sum, 0.0) / (double)_buf.size();
    }
    double rms() const { return std::sqrt(meanSquare()); }

private:
    void rebuild();

    std::vector<float> _buf;
    size_t _pos = 0;
    size_t _filled = 0;
    size_t _sinceRebuild = 0;
    double _sum = 0.0;
    double _sampleRate = 0.0;
    double _seconds = 0.0;
};

// Moving-coil VU movement: a damped second-order system driven by the
// full-wave rectified signal. Tuned so a step reaches 99% in 300 ms with
// about 1.3% overshoot (the VU meter rise-time figures). End stops at 0 and
// at `maxValue` stop the needle dead, as the pins on a real movement do.
class VuBallistics {
public:
    static constexpr double kOmega = 13.42;   // rad/s
    static constexpr double kZeta = 0.81;
    // Rectified average of a sine is 2/pi of its peak; scale so it reads RMS.
    static constexpr double kRectifiedToRms = 1.1107207345395915;   // pi / (2 sqrt 2)

    void configure(double sampleRate);
    void setMaxValue(double v) { _max = v; }
    void reset() { _pos = _vel = 0.0; }

    inline void push(float x) {
        const double drive = std::fabs((double)x) * kRectifiedToRms;
        const double acc = kOmega * kOmega * (drive - _pos) - 2.0 * kZeta * kOmega * _vel;
        _vel += acc * _dt;
        _pos += _vel * _dt;
        if (_pos > _max) { _pos = _max; if (_vel > 0) _vel = 0; }
        else if (_pos < 0.0) { _pos = 0.0; if (_vel < 0) _vel = 0; }
    }

    double value() const { return _pos; }

private:
    double _dt = 1.0 / 48000.0;
    double _pos = 0.0;
    double _vel = 0.0;
    double _max = 1e9;
};

// Quasi-peak rectifier: fast exponential attack, linear-in-dB fall.
class QuasiPeak {
public:
    // attackSeconds: time constant of the charge; fallDbPerSecond: release.
    void configure(double sampleRate, double attackSeconds, double fallDbPerSecond);
    void reset() { _v = 0.0; }

    inline void push(float x) {
        const double r = std::fabs((double)x);
        if (r > _v) _v += (r - _v) * _attack;
        else _v *= _release;
    }

    // Scaled so a steady 1 kHz sine reads its RMS (the rectifier droops a
    // little between peaks, so the scale is measured, not just 1/sqrt 2).
    double value() const { return _v * _gain; }

private:
    double _v = 0.0;
    double _gain = 0.7071067811865476;
    double _attack = 1.0;
    double _release = 1.0;
};

// Peak programme meter flavours for the needle. The timings follow the
// published characteristics of each family; the one-pole attack is an
// approximation, not a certified implementation.
enum class NeedleBallistics : int {
    VU = 0,          // 300 ms moving coil
    PpmDin = 1,      // ~10 ms integration, 20 dB in 1.5 s
    PpmBbc = 2,      // ~10 ms integration (softer), 24 dB in 2.8 s
    PpmNordic = 3,   // ~5 ms integration, 20 dB in 1.7 s
};
constexpr int kNeedleBallisticsCount = 4;

struct PpmTiming {
    double attackSeconds;
    double fallDbPerSecond;
};

// Attack time constants from the tone-burst responses: a 10 ms burst reads
// -1 dB (DIN), -2.5 dB (BBC); a 5 ms burst reads -1 dB (Nordic).
inline PpmTiming ppmTiming(NeedleBallistics b) {
    switch (b) {
        case NeedleBallistics::PpmBbc:    return { 0.010 / 1.386, 24.0 / 2.8 };
        case NeedleBallistics::PpmNordic: return { 0.005 / 2.216, 20.0 / 1.7 };
        case NeedleBallistics::PpmDin:
        default:                          return { 0.010 / 2.216, 20.0 / 1.5 };
    }
}

} // namespace meter
