//
//  SpectrumAnalyzer.h
//  foo_jl_spectrum_mac
//
//  Pulls real-time FFT data from the foobar2000 visualisation stream and maps
//  it into a fixed number of frequency bars, with temporal smoothing and
//  falling peak caps. Pure C++ (no Cocoa), driven once per display frame;
//  all dynamics scale with the frame's duration, so any refresh rate works.
//

#pragma once

#include "../fb2k_sdk.h"
#include <vector>

class SpectrumAnalyzer {
public:
    struct Settings {
        int    barCount   = 48;
        int    fftSize    = 4096;    // power of 2
        int    minHz      = 40;
        int    maxHz      = 18000;
        int    smoothing  = 60;      // attack/decay: 0-100, higher = smoother
        int    smoothingMode = 0;    // spectrum_config::SmoothingMode
        int    rmsMs      = 125;     // RMS: power averaging time constant (ms)
        float  slopeDbPerOct = 0.0f; // level tilt around 1 kHz (0 = flat)
        int    freqScale  = 0;       // spectrum_config::FreqScale
        bool   peakHold    = true;
        float  topDb      = 0.0f;    // level at bar height 1
        float  rangeDb    = 80.0f;   // dB from bar height 1 down to 0

        // Fall dynamics (concrete rates per 1/60 s frame; the UI maps friendly
        // 0-100 sliders to these). Each layer should fall slower than the one below.
        float  shadowFall    = 0.012f;   // shadow band linear fall per frame
        float  peakFall      = 0.0025f;  // peak line linear fall per frame, after its hold
        int    peakHoldFrames = 24;      // frames a peak holds before falling
    };

    SpectrumAnalyzer();

    // Apply new settings. Rebuilds internal band tables when needed.
    void configure(const Settings& settings);

    // Pull the latest spectrum and advance smoothing/peak state by `dt` seconds
    // (the time since the previous tick). Safe to call when nothing is playing
    // (bars decay toward zero).
    // Returns true if live audio data was read, false if idle/decaying.
    bool tick(double dt);

    // Drop the visualisation stream (call when the view goes off-screen).
    // The stream is lazily recreated on the next tick().
    void suspend();

    // Current normalized bar magnitudes (0..1), one per bar.
    const std::vector<float>& bars() const { return _bars; }

    // Slow-decaying dim fill behind the bars (0..1) for the "shadow" depth look.
    const std::vector<float>& shadow() const { return _shadow; }

    // Current normalized peak-cap positions (0..1), one per bar.
    const std::vector<float>& peaks() const { return _peaks; }

    // True while any bar or peak is still above zero (view keeps redrawing).
    bool isActive() const { return _active; }

private:
    void rebuildBands();
    // Display level (0..1) of one bar, read off the first `binCount` bins of _binMag.
    float barTarget(int bar, int binCount) const;
    void releaseStream();

    Settings _settings;
    service_ptr_t<visualisation_stream_v2> _stream;

    // Per-bar frequency bin ranges into the FFT magnitude array.
    std::vector<int> _binLo;   // inclusive
    std::vector<int> _binHi;   // inclusive
    // Fractional bin position of the band centre for bands narrower than one
    // FFT bin (low end), or -1 for bands that aggregate whole bins.
    std::vector<float> _binCenter;
    std::vector<float> _barGain;  // per-bar linear gain from the spectral slope

    std::vector<float> _binMag;   // per-bin magnitude the bars are read from
    std::vector<float> _binPow;   // RMS mode: time-averaged power per bin

    std::vector<float> _bars;     // fast: instantaneous level
    std::vector<float> _shadow;   // medium: falls slower than the bar
    std::vector<float> _peaks;    // slowest: holds, then falls at a steady rate
    std::vector<float> _peakHold; // 1/60 s frames remaining before a peak starts falling

    bool _bandsDirty = true;
    bool _active = false;
    double _lastSampleRate = 0.0;
};
