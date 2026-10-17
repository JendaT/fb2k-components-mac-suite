//
//  SpectrumAnalyzer.h
//  foo_jl_spectrum_mac
//
//  Reads PCM from the foobar2000 visualisation stream, runs a Hann-windowed
//  FFT on it (vDSP) and maps the result into a fixed number of frequency
//  bars, with temporal smoothing and falling peak caps. Pure C++ (no Cocoa),
//  driven once per display frame; all dynamics scale with the frame's
//  duration, so any refresh rate works.
//

#pragma once

#include "../fb2k_sdk.h"
#include <deque>
#include <vector>

struct OpaqueFFTSetup;  // vDSP FFTSetup

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
        int    stereoMode = 0;       // spectrum_config::StereoMode
        int    octaveFraction = 0;   // 0 = per-bin detail, N = average power over 1/N octave per bar
        float  slopeDbPerOct = 0.0f; // level tilt around 1 kHz (0 = flat)
        int    freqScale  = 0;       // spectrum_config::FreqScale
        bool   peakHold    = true;
        float  topDb      = 0.0f;    // level at bar height 1
        float  rangeDb    = 80.0f;   // dB from bar height 1 down to 0

        // Fall dynamics (concrete rates per 1/60 s frame; the UI maps friendly
        // 0-100 sliders to these). Each layer should fall slower than the one below.
        float  shadowFall    = 0.012f;   // shadow band linear fall per frame
        float  peakFall      = 0.0025f;  // peak line linear fall per frame, after its hold
        float  peakHoldSec   = 0.4f;     // how long a peak holds before falling
    };

    SpectrumAnalyzer();
    ~SpectrumAnalyzer();
    SpectrumAnalyzer(const SpectrumAnalyzer&) = delete;
    SpectrumAnalyzer& operator=(const SpectrumAnalyzer&) = delete;

    // Apply new settings. Rebuilds internal band tables when needed.
    void configure(const Settings& settings);

    // Pull the latest audio and advance smoothing/peak state by `dt` seconds
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

    // Side-channel level (0..1) per bar in Mid + side mode, else empty.
    const std::vector<float>& side() const { return _sideBars; }

    // True while any bar or peak is still above zero (view keeps redrawing).
    bool isActive() const { return _active; }

private:
    void rebuildBands();
    // Display level (0..1) of one bar, read off the first `binCount` bins of
    // `mag`; `cumPow` is the running sum of mag^2 (needed for octave smoothing).
    float barTarget(int bar, const std::vector<float>& mag, const std::vector<double>& cumPow, int binCount) const;
    void releaseStream();
    // Fill _mid (and _side) with fftSize samples around stream time `t`.
    bool readAudio(double t);
    // Hann-windowed amplitude spectrum of `in` (fftSize samples) into `mag`.
    void computeSpectrum(const std::vector<float>& in, std::vector<float>& mag);
    // Advance one bar layer (bars or side) from its bin magnitudes.
    void updateLayer(std::vector<float>& layer, std::vector<float>& mag, std::vector<float>& pow,
                     bool live, int binCount, float attackKeep, float decayKeep, float rmsKeep);
    void updatePeaks(double dtSec);
    void clearPeakHistory();

    Settings _settings;
    service_ptr_t<visualisation_stream_v2> _stream;

    // FFT
    OpaqueFFTSetup* _fftSetup = nullptr;
    int _fftLog2 = 0;
    std::vector<float> _window;      // Hann, fftSize
    float _windowSum = 1.0f;
    std::vector<float> _windowed;    // scratch, fftSize
    std::vector<float> _re, _im;     // split-complex scratch, fftSize/2
    std::vector<float> _mid, _side;  // PCM for one FFT frame

    // Per-bar frequency bin ranges into the FFT magnitude array.
    std::vector<int> _binLo;   // inclusive
    std::vector<int> _binHi;   // inclusive
    // Fractional bin position of the band centre for bands narrower than one
    // FFT bin (low end), or -1 for bands that aggregate whole bins.
    std::vector<float> _binCenter;
    std::vector<float> _barGain;  // per-bar linear gain from the spectral slope
    // Octave smoothing: averaging window per bar in fractional bin units
    // (bin b spans b-0.5..b+0.5), or a negative start when the bar is read the
    // normal way (no smoothing, or a window narrower than one bin).
    std::vector<double> _avgFrom, _avgTo;
    std::vector<double> _cumPow;  // scratch: running sum of power per bin

    std::vector<float> _binMag, _binMagSide;  // per-bin magnitude the bars are read from
    std::vector<float> _binPow, _binPowSide;  // RMS mode: time-averaged power per bin

    std::vector<float> _bars;     // fast: instantaneous level
    std::vector<float> _shadow;   // medium: falls slower than the bar
    std::vector<float> _peaks;    // slowest: holds, then falls at a steady rate
    std::vector<float> _sideBars; // side channel, smoothed like _bars

    // Peak line history. The peak is the highest level within the hold
    // window, or what an older level has fallen to since its hold ran out;
    // levels leave the window into _peakQ, a linear-fall envelope of
    // everything older (see updatePeaks).
    std::deque<std::vector<float>> _peakRing;
    std::deque<double> _peakTimes;
    std::vector<std::vector<float>> _peakPool;  // recycled ring entries
    std::vector<float> _peakQ;
    double _peakQTime = 0.0;
    double _clock = 0.0;

    bool _bandsDirty = true;
    bool _active = false;
    double _lastSampleRate = 0.0;
};
