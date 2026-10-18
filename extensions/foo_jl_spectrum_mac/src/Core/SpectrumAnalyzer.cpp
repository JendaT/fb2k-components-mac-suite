//
//  SpectrumAnalyzer.cpp
//  foo_jl_spectrum_mac
//

#include "SpectrumAnalyzer.h"
#include "SpectrumConfig.h"
#include <Accelerate/Accelerate.h>
#include <cmath>
#include <algorithm>

namespace {
    // Convert a normalized magnitude (a full-scale sine reads 1.0) into a
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

    // Peak history keeps at most one entry per 1/60 s; faster frames merge.
    constexpr double kPeakHistoryStep = 1.0 / 60.0;
}

SpectrumAnalyzer::SpectrumAnalyzer() {
    configure(Settings{});
}

SpectrumAnalyzer::~SpectrumAnalyzer() {
    if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
}

float SpectrumAnalyzer::barTarget(int i, const std::vector<float>& mag, const std::vector<double>& cumPow,
                                  int binCount) const {
    const int lo = _binLo[i];
    int hi = _binHi[i];
    if (hi >= binCount) hi = binCount - 1;
    // If the clamp leaves lo > hi, the band loop runs zero times and the bar
    // reads zero.

    const float gain = _barGain[i];
    const float topDb = _settings.topDb, rangeDb = _settings.rangeDb;

    // Unsmoothed level. A bar narrower than a bin is interpolated at its
    // centre, in dB (so the curve does not sag towards the quieter bin), along
    // a monotone cubic through the neighbouring bins: straight segments would
    // show the coarse bin spacing of the bass as corners, and Steffen's
    // tangents round them without ever overshooting a bin's level. A wider bar
    // reads the peak across its bins (punchier than the average).
    const auto plain = [&]() {
        const float centre = _binCenter[i];
        if (centre >= 1.0f && centre < (float)(binCount - 1)) {
            const int b0 = (int)centre;
            const float t = centre - (float)b0;
            const auto at = [&](int b) { return magnitudeToDisplay(mag[b] * gain, topDb, rangeDb); };
            const float d0 = at(b0), d1 = at(b0 + 1);
            const float dPrev = b0 > 1 ? at(b0 - 1) : d0;          // bin 0 is DC
            const float dNext = b0 + 2 < binCount ? at(b0 + 2) : d1;
            const auto tangent = [](float s0, float s1) {
                if (s0 * s1 <= 0.0f) return 0.0f;                   // extremum or flat
                const float limit = std::min({std::fabs(s0), std::fabs(s1), 0.25f * std::fabs(s0 + s1)});
                return (s0 > 0.0f ? 2.0f : -2.0f) * limit;
            };
            const float m0 = tangent(d0 - dPrev, d1 - d0);
            const float m1 = tangent(d1 - d0, dNext - d1);
            const float t2 = t * t, t3 = t2 * t;
            return (2 * t3 - 3 * t2 + 1) * d0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * d1 + (t3 - t2) * m1;
        }
        float m = 0.0f;
        for (int b = lo; b <= hi; ++b) {
            if (mag[b] > m) m = mag[b];
        }
        return magnitudeToDisplay(m * gain, topDb, rangeDb);
    };

    if (_avgFrom[i] < 0.0 || (int)cumPow.size() != binCount + 1) return plain();

    // Octave smoothing: mean power over the window, counting the bins at its
    // edges in proportion to their overlap, so the level slides smoothly from
    // one bar to the next.
    const auto cumAt = [&](double x) {
        const double e = x + 0.5;                 // bin b spans b-0.5..b+0.5
        const int k = std::max(0, std::min((int)e, binCount - 1));
        const double p = (double)mag[k] * mag[k];
        return cumPow[k] + (e - k) * p;
    };
    const double x0 = _avgFrom[i], x1 = _avgTo[i];
    const double meanPow = (cumAt(x1) - cumAt(x0)) / (x1 - x0);
    const float smoothed = magnitudeToDisplay((float)std::sqrt(std::max(0.0, meanPow)) * gain, topDb, rangeDb);
    // Windows of one to two bins blend in from the plain reading, so there is
    // no kink where smoothing takes over at the low end.
    const float w = (float)std::min(1.0, x1 - x0 - 1.0);
    return w >= 1.0f ? smoothed : plain() * (1.0f - w) + smoothed * w;
}

void SpectrumAnalyzer::configure(const SpectrumAnalyzer::Settings& settings) {
    const int oldFftSize = _settings.fftSize;
    const int oldWindow = _settings.window;
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
    if (_settings.peakHoldSec < 0.0f) _settings.peakHoldSec = 0.0f;
    if (_settings.rangeDb < 10.0f) _settings.rangeDb = 10.0f;

    // FFT setup and analysis window for the current size.
    if (!_fftSetup || _settings.fftSize != oldFftSize || _settings.window != oldWindow) {
        const int n = _settings.fftSize;
        if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
        _fftLog2 = (int)std::lround(std::log2((double)n));
        _fftSetup = vDSP_create_fftsetup((vDSP_Length)_fftLog2, kFFTRadix2);
        _window.resize((size_t)n);
        // Periodic (DFT-even) window. Blackman-Harris (4-term, -92 dB
        // sidelobes) gives a cleaner floor than Hann at the cost of wider peaks.
        for (int k = 0; k < n; ++k) {
            const double x = 2.0 * M_PI * k / n;
            _window[(size_t)k] = (float)(_settings.window == spectrum_config::WindowBlackmanHarris
                ? 0.35875 - 0.48829 * std::cos(x) + 0.14128 * std::cos(2 * x) - 0.01168 * std::cos(3 * x)
                : 0.5 - 0.5 * std::cos(x));
        }
        _windowSum = 0.0f;
        for (float w : _window) _windowSum += w;
        _windowed.resize((size_t)n);
        _re.resize((size_t)n / 2);
        _im.resize((size_t)n / 2);
        _mid.assign((size_t)n, 0.0f);
        _side.assign((size_t)n, 0.0f);
        _binPow.clear();
        _binPowSide.clear();
    }

    // Keep the current levels across reconfiguration, resampled when the bar
    // count changes, so a settings tweak or an "Auto" bar count tracking a
    // resize does not blank the display.
    const size_t n = static_cast<size_t>(_settings.barCount);
    resampleTo(_bars, n);
    resampleTo(_shadow, n);
    resampleTo(_peaks, n);
    resampleTo(_peakQ, n);
    for (auto& entry : _peakRing) resampleTo(entry, n);
    _peakPool.clear();
    if (_settings.stereoMode == spectrum_config::StereoMidSide) {
        resampleTo(_sideBars, n);
    } else {
        _sideBars.clear();
        _binPowSide.clear();
    }
    if (_settings.smoothingMode != spectrum_config::SmoothingRms) {
        _binPow.clear();
        _binPowSide.clear();
    }
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
    _avgFrom.assign(bars, -1.0);
    _avgTo.assign(bars, -1.0);
    const double octaveHalf = _settings.octaveFraction > 0
        ? std::pow(2.0, 0.5 / _settings.octaveFraction) : 0.0;

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

        // Octave smoothing window around the bar's centre, in bin units. Where
        // it is narrower than one bin (the low end) the bar is read the normal
        // way above, interpolated between bins.
        if (octaveHalf > 0.0) {
            const double fc = hzAt(((double)i + 0.5) / bars);
            double x0 = fc / octaveHalf / hzPerBin, x1 = fc * octaveHalf / hzPerBin;
            if (x1 - x0 >= 1.0) {
                x0 = std::max(x0, 0.5);                  // skip the DC bin
                x1 = std::min(x1, binCount - 0.5);
                if (x1 > x0) { _avgFrom[i] = x0; _avgTo[i] = x1; }
            }
        }

        if (_settings.slopeDbPerOct != 0.0f) {
            const double fc = hzAt(((double)i + 0.5) / bars);
            _barGain[i] = (float)std::pow(10.0, _settings.slopeDbPerOct * std::log2(fc / 1000.0) / 20.0);
        }
    }

    _bandsDirty = false;
}

bool SpectrumAnalyzer::readAudio(double t) {
    const int n = _settings.fftSize;
    const double sr = _lastSampleRate > 0 ? _lastSampleRate : 44100.0;
    const double len = n / sr;

    // Centre the FFT frame on the playback position, like the core's own
    // spectrum. Right after a start or seek there is no history behind it, so
    // fall back to the frame ending there, then to the one starting there.
    audio_chunk_impl chunk;
    bool ok = _stream->get_chunk_absolute(chunk, t - len * 0.5, len);
    if (!ok) ok = _stream->get_chunk_absolute(chunk, t - len, len);
    if (!ok) ok = _stream->get_chunk_absolute(chunk, t, len);
    if (!ok) return false;

    const unsigned channels = chunk.get_channel_count();
    const size_t frames = chunk.get_sample_count();
    const audio_sample* data = chunk.get_data();
    if (channels == 0 || frames == 0 || data == nullptr) return false;

    const double chunkRate = chunk.get_sample_rate();
    if (chunkRate > 0 && chunkRate != _lastSampleRate) {
        _lastSampleRate = chunkRate;
        _bandsDirty = true;
    }

    // Mid is the channel average (what the core's mono mode shows); side is
    // half the difference of the first two channels.
    const bool wantSide = _settings.stereoMode == spectrum_config::StereoMidSide;
    const size_t count = std::min(frames, (size_t)n);
    const float invCh = 1.0f / (float)channels;
    for (size_t i = 0; i < count; ++i) {
        const audio_sample* f = data + i * channels;
        float sum = 0.0f;
        for (unsigned c = 0; c < channels; ++c) sum += (float)f[c];
        _mid[i] = sum * invCh;
        if (wantSide) _side[i] = channels >= 2 ? 0.5f * ((float)f[0] - (float)f[1]) : 0.0f;
    }
    // A short chunk (start of a track) is zero-padded.
    std::fill(_mid.begin() + (long)count, _mid.end(), 0.0f);
    if (wantSide) std::fill(_side.begin() + (long)count, _side.end(), 0.0f);
    return true;
}

void SpectrumAnalyzer::computeSpectrum(const std::vector<float>& in, std::vector<float>& mag) {
    const int n = _settings.fftSize;
    const int half = n / 2;
    vDSP_vmul(in.data(), 1, _window.data(), 1, _windowed.data(), 1, (vDSP_Length)n);

    DSPSplitComplex split{_re.data(), _im.data()};
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(_windowed.data()), 2, &split, 1, (vDSP_Length)half);
    vDSP_fft_zrip(_fftSetup, &split, 1, (vDSP_Length)_fftLog2, kFFTDirection_Forward);

    // vDSP's real FFT returns twice the DFT. Amplitude of bin k is
    // 2|X[k]| / sum(window), so a full-scale sine reads 1.0: with the factor
    // of two from vDSP that is |zrip[k]| / sum(window).
    mag.resize((size_t)half);
    vDSP_zvabs(&split, 1, mag.data(), 1, (vDSP_Length)half);
    const float scale = 1.0f / _windowSum;
    vDSP_vsmul(mag.data(), 1, &scale, mag.data(), 1, (vDSP_Length)half);
    mag[0] = 0.0f;  // packed DC/Nyquist; DC is never displayed
}

void SpectrumAnalyzer::updateLayer(std::vector<float>& layer, std::vector<float>& mag, std::vector<float>& pow,
                                   bool live, int binCount, float attackKeep, float decayKeep, float rmsKeep) {
    const int bars = (int)layer.size();
    const bool rms = _settings.smoothingMode == spectrum_config::SmoothingRms;
    // Running power sums for octave smoothing, taken from `mag` once it holds
    // the values the bars are read from.
    const auto prepare = [&](int bins) {
        if (_settings.octaveFraction <= 0) { _cumPow.clear(); return; }
        _cumPow.resize((size_t)bins + 1);
        _cumPow[0] = 0.0;
        for (int b = 0; b < bins; ++b) _cumPow[b + 1] = _cumPow[b] + (double)mag[b] * mag[b];
    };

    if (live && rms) {
        // Average power per bin over time and read the bars off the
        // averaged spectrum, so transients decay at one rate everywhere.
        resampleTo(pow, (size_t)binCount);
        for (int b = 0; b < binCount; ++b) {
            pow[b] = pow[b] * rmsKeep + mag[b] * mag[b] * (1.0f - rmsKeep);
            mag[b] = std::sqrt(pow[b]);
        }
        prepare(binCount);
        for (int i = 0; i < bars; ++i) layer[i] = barTarget(i, mag, _cumPow, binCount);
    } else if (live) {
        prepare(binCount);
        for (int i = 0; i < bars; ++i) {
            const float target = barTarget(i, mag, _cumPow, binCount);
            const float prev = layer[i];
            const float keep = (target > prev) ? attackKeep : decayKeep;
            layer[i] = prev * keep + target * (1.0f - keep);
        }
    } else if (rms && !pow.empty()) {
        // No live audio: let the averaged spectrum run down at its own rate.
        const int bins = (int)pow.size();
        mag.resize((size_t)bins);
        for (int b = 0; b < bins; ++b) {
            pow[b] *= rmsKeep;
            mag[b] = std::sqrt(pow[b]);
        }
        prepare(bins);
        for (int i = 0; i < bars; ++i) layer[i] = barTarget(i, mag, _cumPow, bins);
    } else {
        // No live audio: decay everything toward zero.
        for (int i = 0; i < bars; ++i) {
            layer[i] *= decayKeep;
            if (layer[i] < 0.0015f) layer[i] = 0.0f;
        }
    }
}

// The peak line at time t is the highest of every past level L(s), each held
// for the hold time and then falling at the peak fall rate:
//     peak(t) = max over s <= t of  L(s) - rate * max(0, t - s - hold)
//             = max( highest L within [t - hold, t],  Q(t - hold) )
// where Q is the plain linear-fall envelope (no hold) of the levels older than
// the hold window. A per-bar "hold timer" that restarts only on a new maximum
// forgets a slightly lower level that arrives during the hold, so neighbouring
// bars end up seconds apart in their fall and the line shows notches; this
// form keeps every level and stays as smooth across frequency as the bars.
void SpectrumAnalyzer::updatePeaks(double dtSec) {
    _clock += dtSec;
    const size_t n = _bars.size();
    const double hold = _settings.peakHoldSec;
    const double fallPerSec = _settings.peakFall * 60.0;

    // An entry keeps the time of its first frame. Moving it to the latest
    // merged frame would let a fast display (every frame under 1/60 s apart)
    // merge into one entry forever, which never ages out of the hold window
    // and pins the peak line at the loudest level since.
    if (!_peakTimes.empty() && _clock - _peakTimes.back() < kPeakHistoryStep) {
        std::vector<float>& last = _peakRing.back();
        for (size_t i = 0; i < n; ++i) last[i] = std::max(last[i], _bars[i]);
    } else {
        std::vector<float> entry;
        if (!_peakPool.empty()) { entry.swap(_peakPool.back()); _peakPool.pop_back(); }
        entry.assign(_bars.begin(), _bars.end());
        _peakRing.push_back(std::move(entry));
        _peakTimes.push_back(_clock);
    }

    // Levels whose hold has run out fold into the envelope Q.
    if (_peakQ.size() != n) _peakQ.assign(n, 0.0f);
    while (!_peakTimes.empty() && _peakTimes.front() <= _clock - hold) {
        const double s = _peakTimes.front();
        const float fall = (float)(std::max(0.0, s - _peakQTime) * fallPerSec);
        const std::vector<float>& v = _peakRing.front();
        for (size_t i = 0; i < n; ++i) _peakQ[i] = std::max(_peakQ[i] - fall, v[i]);
        _peakQTime = s;
        _peakPool.push_back(std::move(_peakRing.front()));
        _peakRing.pop_front();
        _peakTimes.pop_front();
    }

    const float qFall = (float)(std::max(0.0, (_clock - hold) - _peakQTime) * fallPerSec);
    for (size_t i = 0; i < n; ++i) {
        float p = _peakQ[i] - qFall;
        for (const std::vector<float>& v : _peakRing) p = std::max(p, v[i]);
        _peaks[i] = std::max(p, 0.0f);
    }
}

void SpectrumAnalyzer::clearPeakHistory() {
    for (auto& entry : _peakRing) _peakPool.push_back(std::move(entry));
    _peakRing.clear();
    _peakTimes.clear();
    std::fill(_peakQ.begin(), _peakQ.end(), 0.0f);
    _peakQTime = _clock;
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
    const double rmsTauMs = _settings.rmsMs;
    const float rmsKeep = rmsTauMs > 0.0 ? (float)std::exp(-(frames * 1000.0 / 60.0) / rmsTauMs) : 0.0f;

    bool gotData = false;
    try {
        if (_stream.is_empty()) {
            auto vm = visualisation_manager::get();
            if (vm.is_valid()) {
                vm->create_stream(_stream, 0);
                if (_stream.is_valid()) {
                    _stream->set_channel_mode(visualisation_stream_v2::channel_mode_default);
                    _stream->request_backlog(1.0);  // room for a centred frame at the largest FFT size (32768)
                }
            }
        }

        if (_stream.is_valid()) {
            double t = 0;
            if (_stream->get_absolute_time(t)) gotData = readAudio(t);
        }
    } catch (...) {
        gotData = false;
    }

    if (_bandsDirty) rebuildBands();
    const int binCount = _settings.fftSize / 2;
    const bool wantSide = _settings.stereoMode == spectrum_config::StereoMidSide;

    if (gotData) {
        computeSpectrum(_mid, _binMag);
        if (wantSide) computeSpectrum(_side, _binMagSide);
    }
    updateLayer(_bars, _binMag, _binPow, gotData, binCount, attackKeep, decayKeep, rmsKeep);
    if (wantSide) updateLayer(_sideBars, _binMagSide, _binPowSide, gotData, binCount, attackKeep, decayKeep, rmsKeep);

    // Three timescales, each rising instantly to the bar and falling slower
    // than the layer beneath it: bar (fast) < shadow (medium) < peak (slowest).
    const float kShadowFall = _settings.shadowFall * frames;
    const int bars = _settings.barCount;
    for (int i = 0; i < bars; ++i) {
        // Shadow band: instant rise, steady medium fall.
        const float b = _bars[i];
        if (b >= _shadow[i]) {
            _shadow[i] = b;
        } else {
            _shadow[i] -= kShadowFall;
            if (_shadow[i] < b) _shadow[i] = b;
        }
    }
    updatePeaks(frames / 60.0);

    bool anyActive = false;
    for (int i = 0; i < bars && !anyActive; ++i) {
        if (_bars[i] > 0.0f || _shadow[i] > 0.0f || _peaks[i] > 0.0f) anyActive = true;
    }
    for (float v : _sideBars) {
        if (anyActive) break;
        if (v > 0.0f) anyActive = true;
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
    std::fill(_sideBars.begin(), _sideBars.end(), 0.0f);
    std::fill(_binPow.begin(), _binPow.end(), 0.0f);
    std::fill(_binPowSide.begin(), _binPowSide.end(), 0.0f);
    clearPeakHistory();
    _active = false;
}
