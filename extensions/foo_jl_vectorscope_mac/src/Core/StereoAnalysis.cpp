//
//  StereoAnalysis.cpp
//  foo_jl_vectorscope_mac
//

#include "StereoAnalysis.h"
#include <algorithm>
#include <cmath>

namespace stereo {

namespace {
    const double kPi = 3.14159265358979323846;
    const double kButterworthQ = 0.70710678118654752440;
    // Mean-square level under which a correlation reading is meaningless.
    const double kSilencePower = 1e-7;   // about -70 dBFS
    // Peaks under this do not move the auto-gain (track gaps, fade tails).
    const float  kAutoGainGate = 1e-4f;  // -80 dBFS
    const double kAutoGainEase = 0.15;   // seconds
}

void goniometerPoints(const float* lr, size_t frames, float gain, float* xy) {
    const float g = 0.5f * gain;
    for (size_t i = 0; i < frames; ++i) {
        const float l = lr[2 * i];
        const float r = lr[2 * i + 1];
        xy[2 * i]     = (r - l) * g;
        xy[2 * i + 1] = (l + r) * g;
    }
}

float blockPeak(const float* lr, size_t frames) {
    float peak = 0.0f;
    for (size_t i = 0; i < frames * 2; ++i) {
        const float a = std::fabs(lr[i]);
        if (a > peak) peak = a;   // NaN compares false and is ignored
    }
    return peak;
}

#pragma mark - Biquad

namespace {
    // Keep the corner inside the range where the design stays stable.
    double clampCorner(double sampleRate, double hz) {
        return std::min(std::max(hz, 10.0), sampleRate * 0.45);
    }
}

Biquad Biquad::lowpass(double sampleRate, double hz) {
    const double w0 = 2.0 * kPi * clampCorner(sampleRate, hz) / sampleRate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * kButterworthQ);
    const double a0 = 1.0 + alpha;
    Biquad q;
    q.b0 = (1.0 - cs) * 0.5 / a0;
    q.b1 = (1.0 - cs) / a0;
    q.b2 = q.b0;
    q.a1 = -2.0 * cs / a0;
    q.a2 = (1.0 - alpha) / a0;
    return q;
}

Biquad Biquad::highpass(double sampleRate, double hz) {
    const double w0 = 2.0 * kPi * clampCorner(sampleRate, hz) / sampleRate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * kButterworthQ);
    const double a0 = 1.0 + alpha;
    Biquad q;
    q.b0 = (1.0 + cs) * 0.5 / a0;
    q.b1 = -(1.0 + cs) / a0;
    q.b2 = q.b0;
    q.a1 = -2.0 * cs / a0;
    q.a2 = (1.0 - alpha) / a0;
    return q;
}

void Biquad::flush() {
    if (std::fabs(z1) < 1e-15) z1 = 0.0;
    if (std::fabs(z2) < 1e-15) z2 = 0.0;
}

#pragma mark - ThreeBandSplitter

void ThreeBandSplitter::configure(double sampleRate, double lowHz, double highHz) {
    if (highHz < lowHz) std::swap(lowHz, highHz);
    for (int c = 0; c < 2; ++c) {
        for (int s = 0; s < 2; ++s) {
            _low[c][s]   = Biquad::lowpass(sampleRate, lowHz);
            _midHp[c][s] = Biquad::highpass(sampleRate, lowHz);
            _midLp[c][s] = Biquad::lowpass(sampleRate, highHz);
            _high[c][s]  = Biquad::highpass(sampleRate, highHz);
        }
    }
}

void ThreeBandSplitter::reset() {
    for (int c = 0; c < 2; ++c) {
        for (int s = 0; s < 2; ++s) {
            _low[c][s].reset();
            _midHp[c][s].reset();
            _midLp[c][s].reset();
            _high[c][s].reset();
        }
    }
}

void ThreeBandSplitter::process(const float* lr, size_t frames, float* low, float* mid, float* high) {
    for (int c = 0; c < 2; ++c) {
        Biquad* lo = _low[c];
        Biquad* mh = _midHp[c];
        Biquad* ml = _midLp[c];
        Biquad* hi = _high[c];
        for (size_t i = 0; i < frames; ++i) {
            const float x = lr[2 * i + c];
            low[2 * i + c]  = lo[1].process(lo[0].process(x));
            mid[2 * i + c]  = ml[1].process(ml[0].process(mh[1].process(mh[0].process(x))));
            high[2 * i + c] = hi[1].process(hi[0].process(x));
        }
        for (int s = 0; s < 2; ++s) {
            lo[s].flush(); mh[s].flush(); ml[s].flush(); hi[s].flush();
        }
    }
}

#pragma mark - CorrelationMeter

void CorrelationMeter::configure(double sampleRate, double integrationSeconds) {
    _tau = std::max(integrationSeconds, 0.01);
    _coeff = sampleRate > 0.0 ? 1.0 - std::exp(-1.0 / (_tau * sampleRate)) : 0.0;
}

void CorrelationMeter::reset() {
    _lr = _ll = _rr = 0.0;
}

void CorrelationMeter::process(const float* lr, size_t frames) {
    const double a = _coeff;
    double sLR = _lr, sLL = _ll, sRR = _rr;
    for (size_t i = 0; i < frames; ++i) {
        const double l = lr[2 * i];
        const double r = lr[2 * i + 1];
        sLR += a * (l * r - sLR);
        sLL += a * (l * l - sLL);
        sRR += a * (r * r - sRR);
    }
    // A non-finite sample (broken decoder) would poison the window for good.
    if (!std::isfinite(sLR) || !std::isfinite(sLL) || !std::isfinite(sRR)) {
        sLR = sLL = sRR = 0.0;
    }
    _lr = sLR; _ll = sLL; _rr = sRR;
}

void CorrelationMeter::idle(double seconds) {
    if (seconds <= 0.0) return;
    const double keep = std::exp(-seconds / _tau);
    _lr *= keep; _ll *= keep; _rr *= keep;
}

bool CorrelationMeter::silent() const {
    return (_ll + _rr) * 0.5 < kSilencePower;
}

float CorrelationMeter::value() const {
    if (silent()) return 0.0f;
    const double denom = std::sqrt(_ll * _rr);
    // One channel empty: nothing to correlate against.
    if (denom < kSilencePower * 1e-3) return 0.0f;
    return (float)std::min(1.0, std::max(-1.0, _lr / denom));
}

#pragma mark - AutoGain

void AutoGain::configure(float target, float minGain, float maxGain, double releaseSeconds) {
    _target = target;
    _minGain = minGain;
    _maxGain = std::max(maxGain, minGain);
    _release = std::max(releaseSeconds, 0.01);
}

void AutoGain::reset() {
    _env = 0.0f;
    _gain = 1.0f;
}

float AutoGain::process(float peak, double seconds) {
    if (seconds <= 0.0) return _gain;
    // Silence holds the envelope, so the gain does not creep up to maximum
    // between tracks and blow out the first notes of the next one.
    if (peak >= kAutoGainGate) {
        if (peak > _env) _env = peak;
        else _env = std::max(peak, _env * (float)std::exp(-seconds / _release));
    }
    if (_env <= 0.0f) return _gain;

    const float wanted = std::min(_maxGain, std::max(_minGain, _target / _env));
    _gain += (wanted - _gain) * (float)(1.0 - std::exp(-seconds / kAutoGainEase));
    return _gain;
}

#pragma mark - StereoAnalyzer

void StereoAnalyzer::configure(const Settings& settings) {
    _settings = settings;
    _dirty = true;
}

void StereoAnalyzer::rebuild() {
    _wide.configure(_sampleRate, _settings.integrationSeconds);
    for (CorrelationMeter& m : _bands) {
        m.configure(_sampleRate, _settings.integrationSeconds);
        m.reset();
    }
    _splitter.configure(_sampleRate, _settings.lowHz, _settings.highHz);
    _splitter.reset();
    // Peak lands at 90% of the way to the edge; range -6 dB .. +30 dB.
    _autoGain.configure(0.9f, 0.5f, 31.6f, 3.0);
    _dirty = false;
}

void StereoAnalyzer::process(const float* lr, size_t frames, double sampleRate, float* xy) {
    if (frames == 0 || sampleRate <= 0.0) return;
    if (sampleRate != _sampleRate) {
        _sampleRate = sampleRate;
        _wide.reset();
        _dirty = true;
    }
    if (_dirty) rebuild();

    _wide.process(lr, frames);

    if (_settings.multiband) {
        for (std::vector<float>& s : _scratch) {
            if (s.size() < frames * 2) s.resize(frames * 2);
        }
        _splitter.process(lr, frames, _scratch[BandLow].data(), _scratch[BandMid].data(),
                          _scratch[BandHigh].data());
        for (int b = 0; b < BandCount; ++b) _bands[b].process(_scratch[b].data(), frames);
    }

    if (_settings.autoGain) _autoGain.process(blockPeak(lr, frames), (double)frames / sampleRate);
    goniometerPoints(lr, frames, gain(), xy);
}

void StereoAnalyzer::idle(double seconds) {
    _wide.idle(seconds);
    for (CorrelationMeter& m : _bands) m.idle(seconds);
}

} // namespace stereo
