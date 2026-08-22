//
//  SpectrumAnalyzer.h
//  foo_jl_spectrum_mac
//
//  Pulls real-time FFT data from the foobar2000 visualisation stream and maps
//  it into a fixed number of frequency bars, with temporal smoothing and
//  falling peak caps. Pure C++ (no Cocoa), driven once per display frame.
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
        int    smoothing  = 60;      // 0-100, higher = smoother
        bool   logScale   = true;
        bool   peakHold    = true;
    };

    SpectrumAnalyzer();

    // Apply new settings. Rebuilds internal band tables when needed.
    void configure(const Settings& settings);

    // Pull the latest spectrum and advance smoothing/peak state by one frame.
    // Safe to call when nothing is playing (bars decay toward zero).
    // Returns true if live audio data was read, false if idle/decaying.
    bool tick();

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
    void releaseStream();

    Settings _settings;
    service_ptr_t<visualisation_stream_v2> _stream;

    // Per-bar frequency bin ranges into the FFT magnitude array.
    std::vector<int> _binLo;   // inclusive
    std::vector<int> _binHi;   // inclusive

    std::vector<float> _bars;
    std::vector<float> _shadow;   // slow-decaying fill behind bars
    std::vector<float> _peaks;
    std::vector<float> _peakVel;  // downward velocity per peak cap

    bool _bandsDirty = true;
    bool _active = false;
    double _lastSampleRate = 0.0;
};
