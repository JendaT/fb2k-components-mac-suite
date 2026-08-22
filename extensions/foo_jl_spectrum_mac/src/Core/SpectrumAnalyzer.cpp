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
    inline float magnitudeToDisplay(float mag) {
        if (mag <= 1e-7f) return 0.0f;
        float db = 20.0f * std::log10(mag);
        float v = (db - spectrum_config::kDisplayFloorDb) /
                  (spectrum_config::kDisplayCeilDb - spectrum_config::kDisplayFloorDb);
        if (v < 0.0f) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        return v;
    }

    inline int nextPow2(int v) {
        int p = 1;
        while (p < v) p <<= 1;
        return p;
    }
}

SpectrumAnalyzer::SpectrumAnalyzer() {
    configure(Settings{});
}

void SpectrumAnalyzer::configure(const SpectrumAnalyzer::Settings& settings) {
    _settings = settings;

    // Sanitize
    if (_settings.barCount < 4)   _settings.barCount = 4;
    if (_settings.barCount > 512) _settings.barCount = 512;
    _settings.fftSize = nextPow2(std::max(256, std::min(_settings.fftSize, 32768)));
    if (_settings.minHz < 10)     _settings.minHz = 10;
    if (_settings.maxHz <= _settings.minHz + 100) _settings.maxHz = _settings.minHz + 100;
    if (_settings.smoothing < 0)   _settings.smoothing = 0;
    if (_settings.smoothing > 100) _settings.smoothing = 100;

    const size_t n = static_cast<size_t>(_settings.barCount);
    _bars.assign(n, 0.0f);
    _shadow.assign(n, 0.0f);
    _peaks.assign(n, 0.0f);
    _peakVel.assign(n, 0.0f);
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

    const double minHz = std::min<double>(_settings.minHz, nyquist - 1);
    const double maxHz = std::min<double>(_settings.maxHz, nyquist);
    const double hzPerBin = sr / fftSize;

    for (int i = 0; i < bars; ++i) {
        double f0, f1;
        if (_settings.logScale) {
            const double logMin = std::log10(minHz);
            const double logMax = std::log10(maxHz);
            f0 = std::pow(10.0, logMin + (logMax - logMin) * (double)i / bars);
            f1 = std::pow(10.0, logMin + (logMax - logMin) * (double)(i + 1) / bars);
        } else {
            f0 = minHz + (maxHz - minHz) * (double)i / bars;
            f1 = minHz + (maxHz - minHz) * (double)(i + 1) / bars;
        }

        int lo = (int)std::floor(f0 / hzPerBin);
        int hi = (int)std::ceil(f1 / hzPerBin) - 1;

        // Ensure every bar covers at least one bin and stays in range.
        if (hi < lo) hi = lo;
        if (lo < 1) lo = 1;                          // skip DC bin
        if (hi >= binCount) hi = binCount - 1;
        if (lo > hi) lo = hi;

        _binLo[i] = lo;
        _binHi[i] = hi;
    }

    _bandsDirty = false;
}

bool SpectrumAnalyzer::tick() {
    // Smoothing coefficient: fraction of the previous value retained per frame.
    // attack is faster than decay so bars rise quickly and fall smoothly.
    const float s = _settings.smoothing / 100.0f;
    const float decayKeep  = 0.60f + 0.39f * s;   // ~0.60 .. 0.99
    const float attackKeep = 0.10f + 0.50f * s;   // ~0.10 .. 0.60

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
        const t_size frames = spectrum.get_sample_count();   // == fftSize/2
        const int binCount = (int)frames;

        for (int i = 0; i < bars; ++i) {
            int lo = _binLo[i];
            int hi = _binHi[i];
            if (hi >= binCount) hi = binCount - 1;
            if (lo > hi) { /* keep previous target of 0 */ }

            // Peak magnitude across the band (peak reads punchier than average).
            float mag = 0.0f;
            for (int b = lo; b <= hi; ++b) {
                float m = 0.0f;
                for (unsigned c = 0; c < channels; ++c) {
                    m += (float)std::fabs(data[(size_t)b * channels + c]);
                }
                if (channels > 1) m /= (float)channels;
                if (m > mag) mag = m;
            }

            float target = magnitudeToDisplay(mag);

            float prev = _bars[i];
            float keep = (target > prev) ? attackKeep : decayKeep;
            _bars[i] = prev * keep + target * (1.0f - keep);
        }
    } else {
        // No live audio: decay everything toward zero.
        for (int i = 0; i < bars; ++i) {
            _bars[i] *= decayKeep;
            if (_bars[i] < 0.0015f) _bars[i] = 0.0f;
        }
    }

    bool anyActive = false;
    for (int i = 0; i < bars; ++i) {
        // Slow-decaying shadow fill: jumps up with the bar, eases down slower.
        if (_bars[i] >= _shadow[i]) {
            _shadow[i] = _bars[i];
        } else {
            _shadow[i] *= 0.90f;
            if (_shadow[i] < _bars[i]) _shadow[i] = _bars[i];
        }

        // Falling peak caps with gravity.
        if (_bars[i] > _peaks[i]) {
            _peaks[i] = _bars[i];
            _peakVel[i] = 0.0f;
        } else {
            _peakVel[i] += 0.010f;              // gravity per frame
            _peaks[i] -= _peakVel[i];
            if (_peaks[i] < _bars[i]) { _peaks[i] = _bars[i]; _peakVel[i] = 0.0f; }
            if (_peaks[i] < 0.0f) _peaks[i] = 0.0f;
        }

        if (_bars[i] > 0.0f || _peaks[i] > 0.0f || _shadow[i] > 0.0f) anyActive = true;
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
    std::fill(_peakVel.begin(), _peakVel.end(), 0.0f);
    _active = false;
}
