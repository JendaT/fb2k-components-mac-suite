//
//  SpectrogramEngine.h
//  foo_jl_spectrogram_mac
//
//  Turns a window of mono PCM into one spectrogram column: a normalized level
//  (0..1) per pixel row. Pure C++ on top of Accelerate (no SDK, no Cocoa), so
//  it can be exercised offline with synthetic signals.
//
//  In multi-resolution mode three FFTs share one centre point: a long window
//  resolves bass pitch, a short one keeps treble transients sharp, and rows in
//  the crossover octaves blend the two in dB.
//
//  Reassigned mode gets thin tonal lines without the long window's time smear:
//  each bin's energy is moved to the frequency the signal actually has there
//  (estimated from a second FFT with the window's derivative), so a tone
//  collapses from a several-bin lobe to a line while kicks stay short. A faint
//  copy of the standard spectrum underneath keeps noise and texture visible.
//

#pragma once

#include <Accelerate/Accelerate.h>
#include <cstdint>
#include <vector>

class SpectrogramEngine {
public:
    enum Scale {
        ScaleLog = 0,       // Logarithmic (musically natural)
        ScaleMel = 1,       // Mel (between log and linear)
        ScaleLinear = 2
    };

    enum Mode {
        ModeStandard = 0,       // One window everywhere
        ModeMultiRes = 1,       // 4x window for bass, 1/4 window for treble
        ModeReassigned = 2      // Base window with frequency reassignment, 1/4 window for treble
    };

    enum Window {
        WindowHann = 0,             // Narrow main lobe
        WindowBlackmanHarris = 1    // -92 dB sidelobes, for wide dB ranges
    };

    struct Settings {
        int    fftSize   = 4096;    // base window at 44.1/48 kHz, power of 2
        int    mode      = ModeReassigned;
        int    window    = WindowHann;
        int    scale     = ScaleLog;
        double minHz     = 20.0;
        double maxHz     = 20000.0;
        float  topDb     = 0.0f;    // dBFS mapped to 1.0
        float  rangeDb   = 90.0f;   // dB span mapped to 0..1
        float  slopeDb   = 0.0f;    // tilt around 1 kHz, dB per octave
    };

    SpectrogramEngine();
    ~SpectrogramEngine();
    SpectrogramEngine(const SpectrogramEngine&) = delete;
    SpectrogramEngine& operator=(const SpectrogramEngine&) = delete;

    void configure(const Settings& settings);
    // Pixel rows per column; row 0 is the top (highest frequency).
    void setRows(int rows);
    // Windows are doubled at 88.2/96 kHz and quadrupled above, so time and
    // frequency resolution stay put across sample rates.
    void setSampleRate(double sampleRate);

    int    rows() const { return _rows; }
    double sampleRate() const { return _sampleRate; }
    // Samples renderColumn() reads: the longest window in use.
    int    windowLength();

    // `samples` holds windowLength() mono samples centred on the column's
    // time; `out` receives rows() levels in 0..1.
    void renderColumn(const float* samples, float* out);

    // Position of a frequency along the axis (0 = minHz, 1 = maxHz) and back.
    // Shared with the view so labels and probe line up with the pixels.
    static double fractionForHz(int scale, double minHz, double maxHz, double hz);
    static double hzForFraction(int scale, double minHz, double maxHz, double t);

private:
    struct Stage {
        int size = 0;
        int log2n = 0;
        int offset = 0;             // start within the shared sample window
        int binLo = 0, binHi = -1;  // bins the row table reads (inclusive)
        std::vector<float> window;  // scaled so a full-scale sine reads 0 dB
        std::vector<float> db;      // per-bin level, valid within binLo..binHi
        std::vector<float> dwindow; // derivative of `window`, for reassignment
        float  lobe = 1.0f;         // energy of a tone's whole lobe over its peak bin
        bool   reassign = false;
        std::vector<float> rowDb;   // reassigned level per row (reassign only)
    };

    // How a row reads one stage: interpolate between bins lo and lo + 1 when
    // the row is narrower than the bins (hi < 0), else the peak of lo..hi.
    struct Tap {
        int   lo = 0;
        int   hi = -1;
        float frac = 0.0f;
    };

    struct Row {
        int   a = -1;               // stage index, -1 above Nyquist
        int   b = -1;               // second stage in a crossover, else == a
        float mix = 0.0f;           // weight of b
        float tilt = 0.0f;          // dB added by the slope setting
        Tap   tapA, tapB;
    };

    void rebuild();
    void reassignStage(Stage& stage);
    Tap makeTap(Stage& stage, double f0, double f1, double fc) const;
    float readTap(const Stage& stage, const Tap& tap) const;

    Settings _settings;
    int      _rows = 0;
    double   _sampleRate = 44100.0;
    bool     _dirty = true;
    int      _length = 0;

    FFTSetup _setup = nullptr;
    Stage    _stages[3];            // long, base, short
    std::vector<Row> _rowTable;
    std::vector<float> _windowed, _re, _im, _power;
    std::vector<float> _dRe, _dIm;   // derivative-window spectrum
    std::vector<double> _rowPower;   // reassigned power accumulated per row
    const float* _windowedSource = nullptr;  // samples of the column being rendered
};
