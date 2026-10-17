//
//  SpectrumAnalyzer.cpp
//  foo_jl_spectrum_mac
//

#include "SpectrumAnalyzer.h"
#include "SpectrumConfig.h"
#include <cmath>
#include <algorithm>

namespace {
    // Convert a normalized magnitude (0..1 from KStreamFlagNewFFT) into a
    // display value by mapping a dB window to 0..1. This gives the familiar
    // spectrum-analyzer look where quiet detail is still visible.
    inline float magnitudeToDisplay(float mag, float topDb, float rangeDb) {
        if (mag <= 1e-7f) return 0.0f;
        float db = 20.0f * std::log10(mag);
        float v = (db - (topDb - rangeDb)) / rangeDb;
        if (v < 0.0f) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }

    inline int nextPow2(int v) {
        int p = 1;
        while (p < v) p <<= 1;
        return p;
    }

    // Nearest-neighbour resample along the frequency axis (bars share the same
    // fractional layout at any count). Empty input yields zeros.
    template <typename T>
    void resampleTo(std::vector<T>& v, size_t n) {
        const size_t old = v.size();
        if (old == n) return;
        if (old == 0) { v.assign(n, T{}); return; }
        std::vector<T> out(n);
        for (size_t i = 0; i < n; ++i) {
            out[i] = v[std::min(old - 1, (size_t)(((double)i + 0.5) * old / n))];
        }
        v.swap(out);
    }
}

SpectrumAnalyzer::SpectrumAnalyzer() {
    configure(Settings{});
}

float SpectrumAnalyzer::barTarget(int i, int binCount) const {
    const int lo = _binLo[i];
    int hi = _binHi[i];
    if (hi >= binCount) hi = binCount - 1;
    // If the clamp leaves lo > hi, the band loop runs zero times and the bar
    // reads zero.

    float mag = 0.0f;
    const float centre = _binCenter[i];
    if (centre >= 1.0f && centre < (float)(binCount - 1)) {
        // Narrower than a bin: interpolate at the band centre.
        const int b0 = (int)centre;
        const float t = centre - (float)b0;
        mag = _binMag[b0] * (1.0f - t) + _binMag[b0 + 1] * t;
    } else {
        // Peak magnitude across the band (peak reads punchier than average).
        for (int b = lo; b <= hi; ++b) {
            if (_binMag[b] > mag) mag = _binMag[b];
        }
    }
    return magnitudeToDisplay(mag * _barGain[i], _settings.topDb, _settings.rangeDb);
}

void SpectrumAnalyzer::configure(const SpectrumAnalyzer::Settings& settings) {
    _settings = settings;

    // Sanitize
    if (_settings.barCount < 4)   _settings.barCount = 4;
    if (_settings.barCount > spectrum_config::kMaxBarCount) _settings.barCount = spectrum_config::kMaxBarCount;
    _settings.fftSize = nextPow2(std::max(256, std::min(_settings.fftSize, 32768)));
    if (_settings.minHz < 10)     _settings.minHz = 10;
    if (_settings.maxHz <= _settings.minHz + 100) _settings.maxHz = _settings.minHz + 100;
    if (_settings.smoothing < 0)   _settings.smoothing = 0;
    if (_settings.smoothing > 100) _settings.smoothing = 100;
    _settings.rmsMs = std::max(0, std::min(_settings.rmsMs, spectrum_config::kMaxRmsMs));
    if (_settings.shadowFall < 0.0005f) _settings.shadowFall = 0.0005f;
    if (_settings.peakFall < 0.0001f) _settings.peakFall = 0.0001f;
    if (_settings.peakHoldFrames < 0) _settings.peakHoldFrames = 0;
    if (_settings.rangeDb < 10.0f) _settings.rangeDb = 10.0f;

    // Keep the current levels across reconfiguration, resampled when the bar
    // count changes, so a settings tweak or an "Auto" bar count tracking a
    // resize does not blank the display.
    const size_t n = static_cast<size_t>(_settings.barCount);
    resampleTo(_bars, n);
    resampleTo(_shadow, n);
    resampleTo(_peaks, n);
    resampleTo(_peakHold, n);
    if (_settings.smoothingMode != spectrum_config::SmoothingRms) _binPow.clear();
    _bandsDirty = true;  // bin ranges depend on sample rate, computed lazily
}

void SpectrumAnalyzer::releaseStream() {
    _stream.release();
}

void SpectrumAnalyzer::rebuildBands() {
    const int bars = _settings.barCount;
    const int fftSize = _settings.fftSize;
    const int binCount = fftSize / 2;               // magnitude bins available
    const double sr = _lastSampleRate > 0 ? _lastSampleRate : 44100.0;
    const double nyquist = sr * 0.5;

    _binLo.assign(bars, 0);
    _binHi.assign(bars, 0);
    _binCenter.assign(bars, -1.0f);
    _barGain.assign(bars, 1.0f);

    const double minHz = std::min<double>(_settings.minHz, nyquist - 1);
    const double maxHz = std::min<double>(_settings.maxHz, nyquist);
    const double hzPerBin = sr / fftSize;

    const int scale = _settings.freqScale;
    const double posMin = spectrum_config::freqScalePos(scale, minHz);
    const double posMax = spectrum_config::freqScalePos(scale, maxHz);
    const auto hzAt = [&](double t) {
        return spectrum_config::freqScaleHz(scale, posMin + (posMax - posMin) * t);
    };

    for (int i = 0; i < bars; ++i) {
        const double f0 = hzAt((double)i / bars);
        const double f1 = hzAt((double)(i + 1) / bars);

        int lo = (int)std::floor(f0 / hzPerBin);
        int hi = (int)std::ceil(f1 / hzPerBin) - 1;

        // Ensure every bar covers at least one bin and stays in range. The DC
        // skip must come before hi is raised to lo: a band entirely below bin 1
        // (e.g. 20 Hz at FFT 2048, 21.5 Hz/bin) would otherwise read DC (~0).
        if (lo < 1) lo = 1;                          // skip DC bin
        if (hi < lo) hi = lo;
        if (hi >= binCount) hi = binCount - 1;
        if (lo > hi) lo = hi;

        _binLo[i] = lo;
        _binHi[i] = hi;

        // At the low end several bands can fall inside one FFT bin and would
        // all read the same value, drawing flat steps. Sample those bands at
        // their centre frequency, interpolated between neighbouring bins.
        if (f1 - f0 < hzPerBin) {
            const double fc = hzAt(((double)i + 0.5) / bars);
            // Below bin 1 there is nothing to interpolate towards except DC;
            // hold at bin 1 so the lowest bands read flat instead of dropping.
            _binCenter[i] = (float)std::max(1.0, fc / hzPerBin);
        }

        if (_settings.slopeDbPerOct != 0.0f) {
            const double fc = hzAt(((double)i + 0.5) / bars);
            _barGain[i] = (float)std::pow(10.0, _settings.slopeDbPerOct * std::log2(fc / 1000.0) / 20.0);
        }
    }

    _bandsDirty = false;
}

bool SpectrumAnalyzer::tick(double dt) {
    // All rates are defined per 1/60 s frame; `frames` rescales them to the
    // actual step so motion looks the same at any refresh rate. Clamped so a
    // stall does not turn into one huge step.
    const float frames = (float)std::min(std::max(dt * 60.0, 0.25), 4.0);

    // Smoothing coefficient: fraction of the previous value retained per frame.
    // attack is faster than decay so bars rise quickly and fall smoothly.
    const float s = _settings.smoothing / 100.0f;
    const float decayKeep  = std::pow(0.60f + 0.39f * s, frames);   // ~0.60 .. 0.99 per frame
    const float attackKeep = std::pow(0.10f + 0.50f * s, frames);   // ~0.10 .. 0.60 per frame

    // RMS mode: one-pole average of power with its own time constant.
    const bool rms = _settings.smoothingMode == spectrum_config::SmoothingRms;
    const double rmsTauMs = _settings.rmsMs;
    const float rmsKeep = rmsTauMs > 0.0 ? (float)std::exp(-(frames * 1000.0 / 60.0) / rmsTauMs) : 0.0f;

    audio_chunk_impl spectrum;
    bool gotData = false;

    try {
        if (_stream.is_empty()) {
            auto vm = visualisation_manager::get();
            if (vm.is_valid()) {
                vm->create_stream(_stream, visualisation_manager::KStreamFlagNewFFT);
                if (_stream.is_valid()) {
                    _stream->set_channel_mode(visualisation_stream_v2::channel_mode_mono);
                }
            }
        }

        if (_stream.is_valid()) {
            double t = 0;
            if (_stream->get_absolute_time(t)) {
                if (_stream->get_spectrum_absolute(spectrum, t, _settings.fftSize)) {
                    gotData = true;
                }
            }
        }
    } catch (...) {
        gotData = false;
    }

    const int bars = _settings.barCount;

    if (gotData) {
        const double sr = spectrum.get_sample_rate();
        if (sr > 0 && sr != _lastSampleRate) {
            _lastSampleRate = sr;
            _bandsDirty = true;
        }
        if (_bandsDirty) rebuildBands();

        const audio_sample* data = spectrum.get_data();
        const unsigned channels = spectrum.get_channel_count();
        const int binCount = (int)spectrum.get_sample_count();   // == fftSize/2

        // Magnitude per bin, averaged across channels.
        _binMag.resize((size_t)binCount);
        for (int b = 0; b < binCount; ++b) {
            float m = 0.0f;
            for (unsigned c = 0; c < channels; ++c) {
                m += (float)std::fabs(data[(size_t)b * channels + c]);
            }
            _binMag[b] = channels > 1 ? m / (float)channels : m;
        }

        if (rms) {
            // Average power per bin over time and read the bars off the
            // averaged spectrum, so transients decay at one rate everywhere.
            resampleTo(_binPow, (size_t)binCount);
            for (int b = 0; b < binCount; ++b) {
                _binPow[b] = _binPow[b] * rmsKeep + _binMag[b] * _binMag[b] * (1.0f - rmsKeep);
                _binMag[b] = std::sqrt(_binPow[b]);
            }
            for (int i = 0; i < bars; ++i) _bars[i] = barTarget(i, binCount);
        } else {
            for (int i = 0; i < bars; ++i) {
                const float target = barTarget(i, binCount);
                const float prev = _bars[i];
                const float keep = (target > prev) ? attackKeep : decayKeep;
                _bars[i] = prev * keep + target * (1.0f - keep);
            }
        }
    } else if (rms && !_binPow.empty()) {
        // No live audio: let the averaged spectrum run down at its own rate.
        if (_bandsDirty) rebuildBands();
        const int binCount = (int)_binPow.size();
        _binMag.resize((size_t)binCount);
        for (int b = 0; b < binCount; ++b) {
            _binPow[b] *= rmsKeep;
            _binMag[b] = std::sqrt(_binPow[b]);
        }
        for (int i = 0; i < bars; ++i) _bars[i] = barTarget(i, binCount);
    } else {
        // No live audio: decay everything toward zero.
        for (int i = 0; i < bars; ++i) {
            _bars[i] *= decayKeep;
            if (_bars[i] < 0.0015f) _bars[i] = 0.0f;
        }
    }

    // Three timescales, each rising instantly to the bar and falling slower
    // than the layer beneath it: bar (fast) < shadow (medium) < peak (slowest).
    const float kShadowFall  = _settings.shadowFall * frames;
    const float kPeakHold    = (float)_settings.peakHoldFrames;
    const float kPeakFall    = _settings.peakFall * frames;

    bool anyActive = false;
    for (int i = 0; i < bars; ++i) {
        const float b = _bars[i];

        // Shadow band: instant rise, steady medium fall.
        if (b >= _shadow[i]) {
            _shadow[i] = b;
        } else {
            _shadow[i] -= kShadowFall;
            if (_shadow[i] < b) _shadow[i] = b;
        }

        // Peak line: instant rise, hold, then a steady fall in dB (the
        // peak-meter convention, e.g. IEC 60268-18).
        if (b >= _peaks[i]) {
            _peaks[i] = b;
            _peakHold[i] = kPeakHold;
        } else if (_peakHold[i] > 0.0f) {
            _peakHold[i] -= frames;
        } else {
            _peaks[i] -= kPeakFall;
            if (_peaks[i] < b) _peaks[i] = b;
            if (_peaks[i] < 0.0f) _peaks[i] = 0.0f;
        }

        if (b > 0.0f || _shadow[i] > 0.0f || _peaks[i] > 0.0f) anyActive = true;
    }

    _active = anyActive;
    return gotData;
}

void SpectrumAnalyzer::suspend() {
    // Called when the view goes off-screen: drop the stream so the core can
    // stop the visualisation backend. The stream is lazily recreated on the
    // next tick(). (Do NOT release per-frame while active — a freshly created
    // stream returns no data for its first reads and would never warm up.)
    releaseStream();
    std::fill(_bars.begin(), _bars.end(), 0.0f);
    std::fill(_shadow.begin(), _shadow.end(), 0.0f);
    std::fill(_peaks.begin(), _peaks.end(), 0.0f);
    std::fill(_binPow.begin(), _binPow.end(), 0.0f);
    std::fill(_peakHold.begin(), _peakHold.end(), 0.0f);
    _active = false;
}
