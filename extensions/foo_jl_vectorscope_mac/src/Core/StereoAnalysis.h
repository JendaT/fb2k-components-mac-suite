//
//  StereoAnalysis.h
//  foo_jl_vectorscope_mac
//
//  Stereo-field maths for the vectorscope: goniometer mapping, phase
//  correlation (broadband and three-band) and auto-gain. Pure C++ with no
//  foobar2000 SDK or Cocoa dependency, so it is unit-tested standalone.
//

#pragma once

#include <cstddef>
#include <vector>

namespace stereo {

// Map interleaved L/R frames to goniometer points (x, y in -1..1, y up),
// written as interleaved x/y pairs. Mono is vertical, left-only leans
// upper-left, out-of-phase is horizontal. At gain 1 full-scale input stays
// inside the diamond |x| + |y| <= 1.
void goniometerPoints(const float* lr, size_t frames, float gain, float* xy);

// Largest absolute sample in an interleaved L/R block.
float blockPeak(const float* lr, size_t frames);

// Second-order IIR section (transposed direct form II).
struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;

    static Biquad lowpass(double sampleRate, double hz);    // Butterworth, 12 dB/oct
    static Biquad highpass(double sampleRate, double hz);   // Butterworth, 12 dB/oct

    inline float process(float x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return (float)y;
    }
    void reset() { z1 = z2 = 0.0; }
    // Zero state that has decayed to nothing, before it reaches denormals.
    void flush();
};

// Splits stereo audio into low / mid / high bands with 24 dB/oct
// (Linkwitz-Riley) slopes. Both channels run identical filters, so the phase
// relationship between L and R inside each band is preserved.
class ThreeBandSplitter {
public:
    void configure(double sampleRate, double lowHz, double highHz);
    void reset();
    // Each output receives `frames` interleaved L/R frames.
    void process(const float* lr, size_t frames, float* low, float* mid, float* high);

private:
    // [channel][stage]
    Biquad _low[2][2];      // low-pass at lowHz
    Biquad _midHp[2][2];    // high-pass at lowHz ...
    Biquad _midLp[2][2];    // ... then low-pass at highHz
    Biquad _high[2][2];     // high-pass at highHz
};

// Phase correlation meter: normalised cross-correlation of L and R over an
// exponential time window. +1 = mono, 0 = unrelated or one-sided, -1 = out
// of phase.
class CorrelationMeter {
public:
    void configure(double sampleRate, double integrationSeconds);
    void reset();
    void process(const float* lr, size_t frames);
    // Advance by `seconds` of silence (playback stopped or paused).
    void idle(double seconds);

    float value() const;    // -1..+1; 0 while silent
    bool  silent() const;   // window energy below about -70 dBFS

private:
    double _coeff = 0.0;
    double _tau = 0.5;
    double _lr = 0.0, _ll = 0.0, _rr = 0.0;
};

// Slow gain rider so quiet material still fills the scope. Follows the block
// peak (instant attack, slow release) and eases the gain towards the value
// that puts that peak at `target`.
class AutoGain {
public:
    void configure(float target, float minGain, float maxGain, double releaseSeconds);
    void reset();
    // `peak` is the block's largest absolute sample, `seconds` its duration.
    float process(float peak, double seconds);
    float gain() const { return _gain; }

private:
    float  _target = 0.9f;
    float  _minGain = 0.5f;
    float  _maxGain = 31.6f;
    double _release = 3.0;
    float  _env = 0.0f;
    float  _gain = 1.0f;
};

// Everything the vectorscope needs from one block of audio.
class StereoAnalyzer {
public:
    enum { BandLow = 0, BandMid = 1, BandHigh = 2, BandCount = 3 };

    struct Settings {
        double integrationSeconds = 0.5;   // correlation window
        bool   multiband = false;          // also meter low / mid / high
        double lowHz = 250.0;              // low / mid crossover
        double highHz = 2000.0;            // mid / high crossover
        bool   autoGain = true;
        float  manualGain = 1.0f;          // used when autoGain is off
    };

    void configure(const Settings& settings);

    // Analyse `frames` interleaved L/R frames and write their goniometer
    // points (2 * frames floats) to `xy`.
    void process(const float* lr, size_t frames, double sampleRate, float* xy);
    // Advance the meters by `seconds` with no audio.
    void idle(double seconds);

    float correlation() const { return _wide.value(); }
    bool  silent() const { return _wide.silent(); }
    float bandCorrelation(int band) const { return _bands[band].value(); }
    bool  bandSilent(int band) const { return _bands[band].silent(); }
    float gain() const { return _settings.autoGain ? _autoGain.gain() : _settings.manualGain; }

private:
    void rebuild();

    Settings _settings;
    double _sampleRate = 0.0;
    bool _dirty = true;

    CorrelationMeter  _wide;
    CorrelationMeter  _bands[BandCount];
    ThreeBandSplitter _splitter;
    AutoGain          _autoGain;
    std::vector<float> _scratch[BandCount];
};

} // namespace stereo
