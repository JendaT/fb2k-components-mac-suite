//
//  SpectrogramEngine.cpp
//  foo_jl_spectrogram_mac
//

#include "SpectrogramEngine.h"
#include <algorithm>
#include <cmath>

namespace {
    constexpr int kMinFft = 256;
    constexpr int kMaxFft = 65536;
    constexpr int kMaxLog2 = 16;

    // Crossovers of the multi-resolution mode. Each blends over one octave.
    constexpr double kLowSplitHz  = 200.0;   // long -> base between 200 and 400 Hz
    constexpr double kHighSplitHz = 2000.0;  // base -> short between 2 and 4 kHz

    constexpr float kSilenceDb = -200.0f;

    inline int clampPow2(int v) {
        int p = kMinFft;
        while (p < v && p < kMaxFft) p <<= 1;
        return p;
    }

    inline int log2i(int v) {
        int n = 0;
        while ((1 << n) < v) ++n;
        return n;
    }

    inline double melOf(double hz) { return std::log(1.0 + hz / 700.0); }
    inline double hzOfMel(double mel) { return 700.0 * (std::exp(mel) - 1.0); }
}

SpectrogramEngine::SpectrogramEngine() {
    _setup = vDSP_create_fftsetup(kMaxLog2, kFFTRadix2);
}

SpectrogramEngine::~SpectrogramEngine() {
    if (_setup) vDSP_destroy_fftsetup(_setup);
}

void SpectrogramEngine::configure(const Settings& settings) {
    _settings = settings;
    if (_settings.minHz < 5.0) _settings.minHz = 5.0;
    if (_settings.maxHz < _settings.minHz + 100.0) _settings.maxHz = _settings.minHz + 100.0;
    if (_settings.rangeDb < 10.0f) _settings.rangeDb = 10.0f;
    _dirty = true;
}

void SpectrogramEngine::setRows(int rows) {
    if (rows < 0) rows = 0;
    if (rows == _rows) return;
    _rows = rows;
    _dirty = true;
}

void SpectrogramEngine::setSampleRate(double sampleRate) {
    if (sampleRate <= 0.0 || sampleRate == _sampleRate) return;
    _sampleRate = sampleRate;
    _dirty = true;
}

int SpectrogramEngine::windowLength() {
    if (_dirty) rebuild();
    return _length;
}

double SpectrogramEngine::fractionForHz(int scale, double minHz, double maxHz, double hz) {
    switch (scale) {
        case ScaleLinear:
            return (hz - minHz) / (maxHz - minHz);
        case ScaleMel:
            return (melOf(hz) - melOf(minHz)) / (melOf(maxHz) - melOf(minHz));
        default:
            return (std::log(hz) - std::log(minHz)) / (std::log(maxHz) - std::log(minHz));
    }
}

double SpectrogramEngine::hzForFraction(int scale, double minHz, double maxHz, double t) {
    switch (scale) {
        case ScaleLinear:
            return minHz + (maxHz - minHz) * t;
        case ScaleMel:
            return hzOfMel(melOf(minHz) + (melOf(maxHz) - melOf(minHz)) * t);
        default:
            return std::exp(std::log(minHz) + (std::log(maxHz) - std::log(minHz)) * t);
    }
}

SpectrogramEngine::Tap SpectrogramEngine::makeTap(Stage& stage, double f0, double f1, double fc) const {
    const double binHz = _sampleRate / stage.size;
    const int maxBin = stage.size / 2 - 1;
    const double b0 = f0 / binHz;
    const double b1 = f1 / binHz;

    Tap tap;
    if (b1 - b0 < 2.0) {
        // Narrower than the bins: sample at the row centre. Bin 0 is DC, so
        // rows below bin 1 hold its level instead of fading toward nothing.
        const double c = std::max(1.0, std::min(fc / binHz, (double)maxBin));
        tap.lo = std::min((int)c, maxBin - 1);
        tap.frac = (float)(c - tap.lo);
        tap.hi = -1;
        stage.binLo = std::min(stage.binLo, tap.lo);
        stage.binHi = std::max(stage.binHi, tap.lo + 1);
    } else {
        tap.lo = std::max(1, std::min((int)std::ceil(b0), maxBin));
        tap.hi = std::max(tap.lo, std::min((int)std::floor(b1), maxBin));
        stage.binLo = std::min(stage.binLo, tap.lo);
        stage.binHi = std::max(stage.binHi, tap.hi);
    }
    return tap;
}

void SpectrogramEngine::rebuild() {
    _dirty = false;

    const int rateScale = _sampleRate <= 64000.0 ? 1 : (_sampleRate <= 128000.0 ? 2 : 4);
    const int base = std::min(clampPow2(_settings.fftSize) * rateScale, kMaxFft);
    const bool multi = _settings.multiRes;
    const int sizes[3] = {
        multi ? std::min(base * 4, kMaxFft) : base,
        base,
        multi ? std::max(base / 4, kMinFft) : base
    };
    _length = sizes[0];

    for (int s = 0; s < 3; ++s) {
        Stage& st = _stages[s];
        st.size = sizes[s];
        st.log2n = log2i(st.size);
        st.offset = (_length - st.size) / 2;
        st.binLo = st.size;
        st.binHi = -1;
        st.db.assign(st.size / 2, kSilenceDb);

        st.window.resize(st.size);
        double sum = 0.0;
        for (int n = 0; n < st.size; ++n) {
            const double x = 2.0 * M_PI * n / st.size;
            const double w = _settings.window == WindowBlackmanHarris
                ? 0.35875 - 0.48829 * std::cos(x) + 0.14128 * std::cos(2 * x) - 0.01168 * std::cos(3 * x)
                : 0.5 - 0.5 * std::cos(x);
            st.window[n] = (float)w;
            sum += w;
        }
        // vDSP's real FFT returns twice the mathematical DFT, so a sine of
        // amplitude A peaks at A * sum(window). Dividing by the sum up front
        // makes the squared magnitude read directly in dBFS.
        const float norm = (float)(1.0 / sum);
        vDSP_vsmul(st.window.data(), 1, &norm, st.window.data(), 1, st.size);
    }

    _windowed.resize(_length);
    _re.resize(_length / 2);
    _im.resize(_length / 2);
    _power.resize(_length / 2);

    const double nyquist = _sampleRate * 0.5;
    const int scale = _settings.scale;
    const double minHz = _settings.minHz, maxHz = _settings.maxHz;

    _rowTable.assign(_rows, Row{});
    for (int r = 0; r < _rows; ++r) {
        const double t1 = 1.0 - (double)r / _rows;
        const double t0 = 1.0 - (double)(r + 1) / _rows;
        const double f0 = hzForFraction(scale, minHz, maxHz, t0);
        const double f1 = std::min(hzForFraction(scale, minHz, maxHz, t1), nyquist);
        const double fc = hzForFraction(scale, minHz, maxHz, 0.5 * (t0 + t1));

        Row& row = _rowTable[r];
        if (fc >= nyquist) continue;  // nothing to show above Nyquist

        if (!multi) {
            row.a = row.b = 1;
        } else if (fc < kLowSplitHz * 2.0) {
            row.a = 0; row.b = 1;
            row.mix = (float)std::max(0.0, std::min(1.0, std::log2(fc / kLowSplitHz)));
        } else {
            row.a = 1; row.b = 2;
            row.mix = (float)std::max(0.0, std::min(1.0, std::log2(fc / kHighSplitHz)));
        }
        // Outside a crossover only one stage is read.
        if (row.mix <= 0.0f) { row.b = row.a; }
        else if (row.mix >= 1.0f) { row.a = row.b; row.mix = 0.0f; }

        row.tilt = _settings.slopeDb * (float)std::log2(fc / 1000.0);
        row.tapA = makeTap(_stages[row.a], f0, f1, fc);
        if (row.b != row.a) row.tapB = makeTap(_stages[row.b], f0, f1, fc);
    }
}

float SpectrogramEngine::readTap(const Stage& stage, const Tap& tap) const {
    const float* db = stage.db.data();
    if (tap.hi < 0) {
        return db[tap.lo] + (db[tap.lo + 1] - db[tap.lo]) * tap.frac;
    }
    float peak = db[tap.lo];
    for (int k = tap.lo + 1; k <= tap.hi; ++k) {
        if (db[k] > peak) peak = db[k];
    }
    return peak;
}

void SpectrogramEngine::renderColumn(const float* samples, float* out) {
    if (_dirty) rebuild();
    if (!_setup || _rows <= 0) return;

    for (int s = 0; s < 3; ++s) {
        Stage& st = _stages[s];
        if (st.binHi < st.binLo) continue;  // no row reads this stage

        const int half = st.size / 2;
        vDSP_vmul(samples + st.offset, 1, st.window.data(), 1, _windowed.data(), 1, st.size);
        DSPSplitComplex split = { _re.data(), _im.data() };
        vDSP_ctoz((const DSPComplex*)_windowed.data(), 2, &split, 1, half);
        vDSP_fft_zrip(_setup, &split, 1, st.log2n, kFFTDirection_Forward);
        _im[0] = 0.0f;  // packed format keeps the Nyquist term here

        const int lo = st.binLo;
        const int count = st.binHi - lo + 1;
        DSPSplitComplex used = { _re.data() + lo, _im.data() + lo };
        vDSP_zvmags(&used, 1, _power.data(), 1, count);
        const float eps = 1e-20f, ref = 1.0f;
        vDSP_vsadd(_power.data(), 1, &eps, _power.data(), 1, count);
        vDSP_vdbcon(_power.data(), 1, &ref, st.db.data() + lo, 1, count, 0);
    }

    const float floorDb = _settings.topDb - _settings.rangeDb;
    const float invRange = 1.0f / _settings.rangeDb;
    for (int r = 0; r < _rows; ++r) {
        const Row& row = _rowTable[r];
        if (row.a < 0) { out[r] = 0.0f; continue; }

        float db = readTap(_stages[row.a], row.tapA);
        if (row.b != row.a) {
            db += (readTap(_stages[row.b], row.tapB) - db) * row.mix;
        }
        const float v = (db + row.tilt - floorDb) * invRange;
        out[r] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }
}
